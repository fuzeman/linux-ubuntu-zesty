human_arch	        	= ARM (hard float)
build_arch	        	= arm
header_arch	        	= arm
defconfig	        	= defconfig
flavours	        	= nanopi-neo nanopi-neo-air orangepi-zero sunxi sunxi-extra
build_image	        	= zImage
kernel_file	        	= arch/$(build_arch)/boot/zImage
install_file	    	= vmlinuz
no_dumpfile	        	= true

loader		        	= grub

do_linux_tools	    	= true
do_tools_usbip      	= true
do_tools_cpupower   	= true
do_tools_perf	    	= true

do_common_headers_indep = false
do_dtbs		        	= true
do_libc_dev_package 	= false
