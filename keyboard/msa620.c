#include <linux/module.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>
#include <linux/kthread.h>
#include <linux/input.h>
#include <linux/delay.h>
#include <linux/reboot.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Fernando Oechsler");
MODULE_DESCRIPTION("Driver teclado MSA620 com thread, input, debounce e Led de status");
MODULE_VERSION("1.0");

#define NUM_ROWS 6
#define NUM_COLS 5

/* Varredura / debounce */
#define DEBOUNCE_SAMPLES   4      /* varreduras consecutivas p/ confirmar a tecla */
#define SCAN_INTERVAL_US   5000   /* intervalo entre varreduras (~5 ms)           */
#define COL_SETTLE_US      10     /* estabilizacao da linha apos ativar a coluna  */
#define LED_BLINK_MS       500    /* periodo do pisca do LED quando ocioso        */
#define COMBO_HOLD_MS      3000   /* F5+ESC+0 segurados por 3s -> reboot          */
/* Debounce efetivo ~= DEBOUNCE_SAMPLES * SCAN_INTERVAL_US ~= 20 ms */

static struct gpio_descs *row_gpios;
static struct gpio_descs *col_gpios;
static struct gpio_desc *ledtec_gpio;

static struct input_dev *input_dev;
static struct task_struct *keyboard_task;

/* Key map */
static const int key_map[NUM_ROWS][NUM_COLS] = {
    {KEY_F5, KEY_F4, KEY_F3, KEY_F2, KEY_F1},
    {KEY_UP, -1, KEY_3, KEY_2, KEY_1},
    {KEY_RIGHT, KEY_LEFT, -1, -1, -1},
    {KEY_DOWN, -1, KEY_6, KEY_5, KEY_4},
    {KEY_ENTER, KEY_ESC, KEY_9, KEY_8, KEY_7},
    {-1, -1 , -1, KEY_0, -1}
};

/*
 * Debounce nao-bloqueante por integracao de amostras.
 *
 * key_state    -> estado ja confirmado (debounced) de cada tecla
 * debounce_cnt -> nº de varreduras seguidas em que a leitura crua difere
 *                 do estado confirmado; ao atingir DEBOUNCE_SAMPLES a
 *                 mudanca e aceita e o evento e enviado.
 *
 * A varredura nunca fica presa em uma tecla: cada tecla e amostrada uma
 * vez por ciclo. Ruido/contato em uma linha so mexe no contador daquela
 * tecla, sem atrasar a leitura das demais.
 */
static bool key_state[NUM_ROWS][NUM_COLS];
static u8   debounce_cnt[NUM_ROWS][NUM_COLS];

/* Thread de varredura */
static int keyboard_thread_fn(void *data) {
    bool led_state = false;
    unsigned long led_jiffies = jiffies;
    bool combo_held = false;          /* combo de reboot em andamento */
    unsigned long combo_since = 0;    /* jiffies de quando o combo comecou */

    while (!kthread_should_stop()) {
        bool any_pressed = false;
        bool changed = false;
        int col, row;

        for (col = 0; col < NUM_COLS; col++) {
            /* Ativa coluna (LOW) e deixa a linha estabilizar */
            gpiod_set_value(col_gpios->desc[col], 0);
            udelay(COL_SETTLE_US);

            for (row = 0; row < NUM_ROWS; row++) {
                int keycode = key_map[row][col];
                bool raw_pressed;

                if (keycode == -1)
                    continue;

                /* linha em pull-up: pressionado => nivel 0 */
                raw_pressed = !gpiod_get_value(row_gpios->desc[row]);

                if (raw_pressed != key_state[row][col]) {
                    /* leitura difere do estado confirmado: integra amostras */
                    if (++debounce_cnt[row][col] >= DEBOUNCE_SAMPLES) {
                        key_state[row][col] = raw_pressed;
                        debounce_cnt[row][col] = 0;
                        input_report_key(input_dev, keycode, raw_pressed);
                        changed = true;
                    }
                } else {
                    /* leitura coincide com o estado confirmado: zera o ruido */
                    debounce_cnt[row][col] = 0;
                }

                if (key_state[row][col])
                    any_pressed = true;
            }

            /* Desativa coluna (HIGH) */
            gpiod_set_value(col_gpios->desc[col], 1);
        }

        /* Um unico sync por varredura, somente quando houve mudanca */
        if (changed)
            input_sync(input_dev);

        /* Combo de manutencao: F5(0,0) + ESC(4,1) + '0'(5,3) por 3s -> reboot */
        if (key_state[0][0] && key_state[4][1] && key_state[5][3]) {
            if (!combo_held) {
                combo_held = true;
                combo_since = jiffies;
            } else if (time_after(jiffies,
                                  combo_since + msecs_to_jiffies(COMBO_HOLD_MS))) {
                pr_info("msa620: combo F5+ESC+0 (3s) -> reboot\n");
                combo_held = false;   /* nao repetir */
                orderly_reboot();     /* reboot gracioso via userspace/systemd */
            }
        } else {
            combo_held = false;
        }

        /* LED: aceso fixo com tecla pressionada, piscando quando ocioso */
        if (any_pressed) {
            gpiod_set_value(ledtec_gpio, 0);   /* aceso */
            led_state = false;
            led_jiffies = jiffies;
        } else if (time_after(jiffies, led_jiffies + msecs_to_jiffies(LED_BLINK_MS))) {
            led_state = !led_state;
            gpiod_set_value(ledtec_gpio, led_state);
            led_jiffies = jiffies;
        }

        /* Dorme entre varreduras: nao trava a CPU e define o passo do debounce */
        usleep_range(SCAN_INTERVAL_US, SCAN_INTERVAL_US + 1000);
    }

    return 0;
}

/* Probe */
static int msa620_probe(struct platform_device *pdev) {
    int ret, i;

    row_gpios = gpiod_get_array(&pdev->dev, "row", GPIOD_IN);
    if (IS_ERR(row_gpios))
        return PTR_ERR(row_gpios);

    col_gpios = gpiod_get_array(&pdev->dev, "col", GPIOD_OUT_HIGH);
    if (IS_ERR(col_gpios)) {
        ret = PTR_ERR(col_gpios);
        goto err_rows;
    }

    ledtec_gpio = gpiod_get(&pdev->dev, "ledtec", GPIOD_OUT_LOW);
    if (IS_ERR(ledtec_gpio)) {
        ret = PTR_ERR(ledtec_gpio);
        goto err_cols;
    }

    input_dev = input_allocate_device();
    if (!input_dev) {
        ret = -ENOMEM;
        goto err_led;
    }

    input_dev->name = "msa620-keyboard";
    input_dev->phys = "gpio/msa620";
    input_dev->id.bustype = BUS_HOST;
    input_dev->evbit[0] = BIT_MASK(EV_KEY);

    for (i = 0; i < NUM_ROWS; i++) {
        int j;
        for (j = 0; j < NUM_COLS; j++) {
            if (key_map[i][j] != -1)
                set_bit(key_map[i][j], input_dev->keybit);
        }
    }

    ret = input_register_device(input_dev);
    if (ret)
        goto err_input;

    keyboard_task = kthread_run(keyboard_thread_fn, NULL, "msa620_kb_thread");
    if (IS_ERR(keyboard_task)) {
        ret = PTR_ERR(keyboard_task);
        goto err_input_reg;
    }

    dev_info(&pdev->dev, "msa620 keyboard driver loaded\n");
    return 0;

err_input_reg:
    input_unregister_device(input_dev);
    input_dev = NULL;
err_input:
    input_free_device(input_dev);
err_led:
    gpiod_put(ledtec_gpio);
err_cols:
    gpiod_put_array(col_gpios);
err_rows:
    gpiod_put_array(row_gpios);
    return ret;
}

/* Remove */
static void msa620_remove(struct platform_device *pdev) {
    kthread_stop(keyboard_task);
    input_unregister_device(input_dev);
    gpiod_put(ledtec_gpio);
    gpiod_put_array(col_gpios);
    gpiod_put_array(row_gpios);
    dev_info(&pdev->dev, "msa620 keyboard driver unloaded\n");
}

/* Match */
static const struct of_device_id msa620_of_match[] = {
    { .compatible = "keyboard,msa620" },
    { }
};
MODULE_DEVICE_TABLE(of, msa620_of_match);

/* Platform driver */
static struct platform_driver msa620_driver = {
    .probe = msa620_probe,
    .remove = msa620_remove,
    .driver = {
        .name = "msa620_keyboard",
        .of_match_table = msa620_of_match,
    },
};

module_platform_driver(msa620_driver);
