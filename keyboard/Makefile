MODULE_NAME = msa620

obj-m += $(MODULE_NAME).o

KERNEL_DIR = /lib/modules/$(shell uname -r)/build
TEMP_DIR = /tmp/backup_dtb
OVERLAY_DIR = /boot/firmware/overlays
MODULE_DIR = /lib/modules/$(shell uname -r)/kernel/drivers

CONFIG_FILE = /boot/firmware/config.txt
MODULE_FILE = /etc/modules

TREE_CONFIG = dtoverlay=msa620

all:
	make -C $(KERNEL_DIR) M=$(shell pwd) modules

install:
	sudo cp $(MODULE_NAME).ko $(MODULE_DIR)
	sudo cp $(MODULE_NAME).dtbo $(OVERLAY_DIR)/
	
	@echo "$(MODULE_NAME)" | sudo tee -a $(MODULE_FILE)
	@echo "$(TREE_CONFIG)" | sudo tee -a $(CONFIG_FILE)
	
	sudo depmod -a
	sudo insmod $(MODULE_NAME).ko

clean:
	mkdir -p $(TEMP_DIR)
	mv $(MODULE_NAME).dtbo $(TEMP_DIR)/
	
	make -C $(KERNEL_DIR) M=$(shell pwd) clean
	
	sudo rm -f $(OVERLAY_DIR)/$(MODULE_NAME).dtbo
	sudo rm -f $(MODULE_DIR)/$(MODULE_NAME).ko	
	
	sudo sed -i '/$(MODULE_NAME)/d' $(MODULE_FILE)
	sudo sed -i '/msa620/d' $(CONFIG_FILE)
	
	mv $(TEMP_DIR)/$(MODULE_NAME).dtbo ./
	rm -rf $(TEMP_DIR)
	
	sudo rmmod $(MODULE_NAME)
