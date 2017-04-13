human_arch	        = ARMv8
build_arch	        = arm64
header_arch	        = arm64
defconfig	        = defconfig
flavours	        = nanopi-a64 pine-a64 sunxi sunxi-extra
build_image	        = Image.gz
kernel_file	        = arch/$(build_arch)/boot/Image.gz
install_file	    = vmlinuz
no_dumpfile	        = true

loader		        = grub

do_extras_package   = true
do_linux_tools	    = true
do_tools_usbip      = true
do_tools_cpupower   = true
do_tools_perf	    = true

do_dtbs		        = true
do_libc_dev_package = false
