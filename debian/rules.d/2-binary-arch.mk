# We don't want make removing intermediary stamps
.SECONDARY :

# Prepare the out-of-tree build directory
ifeq ($(do_full_source),true)
build_cd = cd $(builddir)/$*; #
build_O  =
else
build_cd =
build_O  = O=$(builddir)/$*
endif

# Typically supplied from the arch makefile, e.g., debian.master/control.d/armhf.mk
ifneq ($(gcc),)
kmake += CC=$(CROSS_COMPILE)$(gcc)
endif

shlibdeps_opts = $(if $(CROSS_COMPILE),-- -l$(CROSS_COMPILE:%-=/usr/%)/lib)

$(stampdir)/stamp-prepare-%: config-prepare-check-%
	@echo Debug: $@
	@mkdir -p $(stampdir)
	@touch $@
$(stampdir)/stamp-prepare-tree-%: target_flavour = $*
$(stampdir)/stamp-prepare-tree-%: $(commonconfdir)/config.common.$(family) $(archconfdir)/config.common.$(arch) $(archconfdir)/config.flavour.%
	@echo Debug: $@
	install -d $(builddir)/$*
	touch $(builddir)/$*/ubuntu-build
	[ "$(do_full_source)" != 'true' ] && true || \
		rsync -a --exclude debian --exclude debian.master --exclude $(DEBIAN) * $(builddir)/$*
	cat $^ | sed -e 's/.*CONFIG_VERSION_SIGNATURE.*/CONFIG_VERSION_SIGNATURE="Ubuntu $(release)-$(revision)-$* $(raw_kernelversion)"/' > $(builddir)/$*/.config
	find $(builddir)/$* -name "*.ko" | xargs rm -f
	$(build_cd) $(kmake) $(build_O) -j1 silentoldconfig prepare scripts

	mkdir -p $(stampdir)
	touch $@

# Used by developers as a shortcut to prepare a tree for compilation.
prepare-%: $(stampdir)/stamp-prepare-%
	@echo Debug: $@
# Used by developers to allow efficient pre-building without fakeroot.
build-%: $(stampdir)/stamp-build-%
	@echo Debug: $@

define build_zfs =
	#
	# SPL/ZFS wants a fully built kernel before you can configure and build.
	# It seems to be impossible to tease out the application configuration
	# from the modules, but at least one can build just the modules.
	#
	install -d $(builddir)/$*/spl
	rsync -a --exclude=dkms.conf --delete spl/ $(builddir)/$*/spl/
	cd $(builddir)/$*/spl; sh autogen.sh; sh configure $(splopts)
	$(kmake) -C $(builddir)/$*/spl/module $(conc_level)

	install -d $(builddir)/$*/zfs
	rsync -a --exclude=dkms.conf --delete zfs/ $(builddir)/$*/zfs/
	cd $(builddir)/$*/zfs; sh autogen.sh; sh configure $(zfsopts)
	$(kmake) -C $(builddir)/$*/zfs/module $(conc_level)
endef

# Do the actual build, including image and modules
$(stampdir)/stamp-build-%: target_flavour = $*
$(stampdir)/stamp-build-%: splopts  = --with-linux=$(CURDIR)
$(stampdir)/stamp-build-%: splopts += --with-linux-obj=$(builddir)/$*
$(stampdir)/stamp-build-%: zfsopts  = $(splopts)
$(stampdir)/stamp-build-%: zfsopts += --with-spl=$(builddir)/$*/spl
$(stampdir)/stamp-build-%: zfsopts += --with-spl-obj=$(builddir)/$*/spl
$(stampdir)/stamp-build-%: zfsopts += --prefix=/usr --with-config=kernel
$(stampdir)/stamp-build-%: bldimg = $(call custom_override,build_image,$*)
$(stampdir)/stamp-build-%: enable_zfs = $(call custom_override,do_zfs,$*)
$(stampdir)/stamp-build-%: $(stampdir)/stamp-prepare-%
	@echo Debug: $@ build_image $(build_image) bldimg $(bldimg)
	$(build_cd) $(kmake) $(build_O) $(conc_level) $(bldimg) modules $(if $(filter true,$(do_dtbs)),dtbs)

	$(if $(filter true,$(enable_zfs)),$(call build_zfs))

	@mkdir -p $(stampdir)
	@touch $@

define install_zfs =
	cd $(builddir)/$*/spl/module; \
		$(kmake) -C $(builddir)/$* SUBDIRS=`pwd` modules_install $(splopts)
	cd $(builddir)/$*/zfs/module; \
		$(kmake) -C $(builddir)/$* SUBDIRS=`pwd` modules_install $(zfsopts)
endef

# Install the finished build
install-%: pkgdir = $(stagedir)/$(bin_pkg_name)-$*
install-%: pkgdir_ex = $(stagedir)/$(extra_pkg_name)-$*
install-%: bindoc = $(pkgdir)/usr/share/doc/$(bin_pkg_name)-$*
install-%: dbgpkgdir = $(stagedir)/$(bin_pkg_name)-$*-dbgsym
install-%: signed = $(stagedir)/$(bin_pkg_name)-signed
install-%: toolspkgdir = $(stagedir)/$(tools_flavour_pkg_name)-$*
install-%: cloudpkgdir = $(stagedir)/$(cloud_flavour_pkg_name)-$*
install-%: basepkg = $(hdrs_pkg_name)
install-%: indeppkg = $(indep_hdrs_pkg_name)
install-%: kernfile = $(call custom_override,kernel_file,$*)
install-%: instfile = $(call custom_override,install_file,$*)
install-%: hdrdir = $(stagedir)/$(basepkg)-$*/usr/src/$(basepkg)-$*
install-%: target_flavour = $*
install-%: MODHASHALGO=sha512
install-%: MODSECKEY=$(builddir)/$*/certs/signing_key.pem
install-%: MODPUBKEY=$(builddir)/$*/certs/signing_key.x509
install-%: build_dir=$(builddir)/$*
install-%: enable_zfs = $(call custom_override,do_zfs,$*)
install-%: splopts  = INSTALL_MOD_STRIP=1
install-%: splopts += INSTALL_MOD_PATH=$(pkgdir)/
install-%: splopts += INSTALL_MOD_DIR=kernel/zfs
install-%: splopts += $(conc_level)
install-%: zfsopts  = $(splopts)
install-%: checks-%
	@echo Debug: $@ kernel_file $(kernel_file) kernfile $(kernfile) install_file $(install_file) instfile $(instfile)
	dh_testdir
	dh_testroot
	dh_clean -k -p$(bin_pkg_name)-$*
	dh_clean -k -p$(hdrs_pkg_name)-$*
ifneq ($(skipdbg),true)
	dh_clean -k -p$(dbg_pkg_name)-$*
endif

	# The main image
	# compress_file logic required because not all architectures
	# generate a zImage automatically out of the box
ifeq ($(compress_file),)
	install -m600 -D $(builddir)/$*/$(kernfile) \
		$(pkgdir)/boot/$(instfile)-$(abi_release)-$*
else
	install -d $(pkgdir)/boot
	gzip -c9v $(builddir)/$*/$(kernfile) > \
		$(pkgdir)/boot/$(instfile)-$(abi_release)-$*
	chmod 600 $(pkgdir)/boot/$(instfile)-$(abi_release)-$*
endif

ifeq ($(uefi_signed),true)
	install -d $(signed)/$(release)-$(revision)
	# Check to see if this supports handoff, if not do not sign it.
	# Check the identification area magic and version >= 0x020b
	handoff=`dd if="$(pkgdir)/boot/$(instfile)-$(abi_release)-$*" bs=1 skip=514 count=6 2>/dev/null | od -s | gawk '($$1 == 0 && $$2 == 25672 && $$3 == 21362 && $$4 >= 523) { print "GOOD" }'`; \
	if [ "$$handoff" = "GOOD" ]; then \
		cp -p $(pkgdir)/boot/$(instfile)-$(abi_release)-$* \
			$(signed)/$(release)-$(revision)/$(instfile)-$(abi_release)-$*.efi; \
	fi
endif

	install -m644 $(builddir)/$*/.config \
		$(pkgdir)/boot/config-$(abi_release)-$*
	install -m644 $(abidir)/$* \
		$(pkgdir)/boot/abi-$(abi_release)-$*
	install -m600 $(builddir)/$*/System.map \
		$(pkgdir)/boot/System.map-$(abi_release)-$*
	if [ "$(filter true,$(do_dtbs))" ]; then \
		$(build_cd) $(kmake) $(build_O) $(conc_level) dtbs_install \
			INSTALL_DTBS_PATH=$(pkgdir)/lib/firmware/$(abi_release)-$*/device-tree; \
		( cd $(pkgdir)/lib/firmware/$(abi_release)-$*/ && find device-tree -print ) | \
		while read dtb_file; do \
			echo "$$dtb_file ?" >> $(DEBIAN)/d-i/firmware/$(arch)/kernel-image; \
		done; \
	fi
ifeq ($(no_dumpfile),)
	makedumpfile -g $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$* \
		-x $(builddir)/$*/vmlinux
	chmod 0600 $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$*
endif

	$(build_cd) $(kmake) $(build_O) $(conc_level) modules_install $(vdso) \
		INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$(pkgdir)/ \
		INSTALL_FW_PATH=$(pkgdir)/lib/firmware/$(abi_release)-$*

	$(if $(filter true,$(enable_zfs)),$(call install_zfs))

	#
	# Build module blacklists:
	#  - blacklist all watchdog drivers (LP:1432837)
	#
	install -d $(pkgdir)/lib/modprobe.d
	echo "# Kernel supplied blacklist for $(src_pkg_name) $(abi_release)-$* $(arch)" \
		>$(pkgdir)/lib/modprobe.d/blacklist_$(src_pkg_name)_$(abi_release)-$*.conf
	for conf in $(arch)-$* $(arch) common.conf; do \
		if [ -f $(DEBIAN)/modprobe.d/$$conf ]; then \
			echo "# modprobe.d/$$conf"; \
			cat $(DEBIAN)/modprobe.d/$$conf; \
		fi; \
	done >>$(pkgdir)/lib/modprobe.d/blacklist_$(src_pkg_name)_$(abi_release)-$*.conf
	echo "# Autogenerated watchdog blacklist" \
		>>$(pkgdir)/lib/modprobe.d/blacklist_$(src_pkg_name)_$(abi_release)-$*.conf
	ls -1 $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/watchdog/ | \
		sed -e 's/^/blacklist /' -e 's/.ko$$//' | \
		sort -u \
		>>$(pkgdir)/lib/modprobe.d/blacklist_$(src_pkg_name)_$(abi_release)-$*.conf

ifeq ($(do_extras_package),true)
	#
	# Remove all modules not in the inclusion list.
	#
	if [ -f $(DEBIAN)/control.d/$(target_flavour).inclusion-list ] ; then \
		/sbin/depmod -v -b $(pkgdir) $(abi_release)-$* | \
			sed -e "s@$(pkgdir)/lib/modules/$(abi_release)-$*/kernel/@@g" | \
			awk '{ print $$1 " " $$NF}' >$(build_dir)/module-inclusion.depmap; \
		mkdir -p $(pkgdir_ex)/lib/modules/$(abi_release)-$*; \
		mv $(pkgdir)/lib/modules/$(abi_release)-$*/kernel \
			$(pkgdir_ex)/lib/modules/$(abi_release)-$*/kernel; \
		$(SHELL) $(DROOT)/scripts/module-inclusion --master \
			$(pkgdir_ex)/lib/modules/$(abi_release)-$*/kernel \
			$(pkgdir)/lib/modules/$(abi_release)-$*/kernel \
			$(DEBIAN)/control.d/$(target_flavour).inclusion-list \
			$(build_dir)/module-inclusion.depmap 2>&1 | \
				tee $(target_flavour).inclusion-list.log; \
		/sbin/depmod -b $(pkgdir) -ea -F $(pkgdir)/boot/System.map-$(abi_release)-$* \
			$(abi_release)-$* 2>&1 |tee $(target_flavour).depmod.log; \
		if [ `grep -c 'unknown symbol' $(target_flavour).depmod.log` -gt 0 ]; then \
			echo "EE: Unresolved module dependencies in base package!"; \
			exit 1; \
		fi \
	fi
endif

ifeq ($(no_dumpfile),)
	makedumpfile -g $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$* \
		-x $(builddir)/$*/vmlinux
	chmod 0600 $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$*
endif
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/build
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/source

	# Some initramfs-tools specific modules
	install -d $(pkgdir)/lib/modules/$(abi_release)-$*/initrd
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/video/vesafb.ko ]; then\
	  $(LN) $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/video/vesafb.ko \
		$(pkgdir)/lib/modules/$(abi_release)-$*/initrd/; \
	fi

	# Now the image scripts
	install -d $(pkgdir)/DEBIAN
	for script in postinst postrm preinst prerm; do				\
	  sed -e 's/=V/$(abi_release)-$*/g' -e 's/=K/$(instfile)/g'		\
	      -e 's/=L/$(loader)/g'         -e 's@=B@$(build_arch)@g'		\
	       $(DROOT)/control-scripts/$$script > $(pkgdir)/DEBIAN/$$script;	\
	  chmod 755 $(pkgdir)/DEBIAN/$$script;					\
	done
ifeq ($(do_extras_package),true)
	# Install the postinit/postrm scripts in the extras package.
	if [ -f $(DEBIAN)/control.d/$(target_flavour).inclusion-list ] ; then	\
		install -d $(pkgdir_ex)/DEBIAN;					\
		for script in postinst postrm ; do				\
			sed -e 's/=V/$(abi_release)-$*/g' -e 's/=K/$(instfile)/g'		\
			    -e 's/=L/$(loader)/g'         -e 's@=B@$(build_arch)@g'		\
			    debian/control-scripts/extra-post > $(pkgdir_ex)/DEBIAN/$$script; \
			chmod 755 $(pkgdir_ex)/DEBIAN/$$script;			\
		done;								\
	fi
endif

	# Install the full changelog.
ifeq ($(do_doc_package),true)
	install -d $(bindoc)
	cat $(DEBIAN)/changelog $(DEBIAN)/changelog.historical | \
		gzip -9 >$(bindoc)/changelog.Debian.old.gz
	chmod 644 $(bindoc)/changelog.Debian.old.gz
endif

ifneq ($(skipsub),true)
	for sub in $($(*)_sub); do					\
		if ! (TO=$$sub FROM=$* ABI_RELEASE=$(abi_release) $(SHELL)		\
			$(DROOT)/scripts/sub-flavour); then exit 1; fi;		\
		/sbin/depmod -b $(stagedir)/$(bin_pkg_name)-$$sub		\
			-ea -F $(stagedir)/$(bin_pkg_name)-$$sub/boot/System.map-$(abi_release)-$* \
			$(abi_release)-$*;					\
		install -d $(stagedir)/$(bin_pkg_name)-$$sub/DEBIAN;	\
		for script in postinst postrm preinst prerm; do			\
			sed -e 's/=V/$(abi_release)-$*/g'			\
			    -e 's/=K/$(instfile)/g'				\
			    -e 's/=L/$(loader)/g'				\
			    -e 's@=B@$(build_arch)@g'				\
				$(DROOT)/control-scripts/$$script >		\
				$(stagedir)/$(bin_pkg_name)-$$sub/DEBIAN/$$script;\
			chmod 755  $(stagedir)/$(bin_pkg_name)-$$sub/DEBIAN/$$script;\
		done;								\
	done
endif

ifneq ($(skipdbg),true)
	# Debug image is simple
	install -m644 -D $(builddir)/$*/vmlinux \
		$(dbgpkgdir)/usr/lib/debug/boot/vmlinux-$(abi_release)-$*
	$(build_cd) $(kmake) $(build_O) modules_install $(vdso) \
		INSTALL_MOD_PATH=$(dbgpkgdir)/usr/lib/debug
	# Add .gnu_debuglink sections to each stripped .ko
	# pointing to unstripped verson
	find $(pkgdir) -name '*.ko' | sed 's|$(pkgdir)||'| while read module ; do \
		if [[ -f "$(dbgpkgdir)/usr/lib/debug/$$module" ]] ; then \
			$(CROSS_COMPILE)objcopy \
				--add-gnu-debuglink=$(dbgpkgdir)/usr/lib/debug/$$module \
				$(pkgdir)/$$module; \
			if grep -q CONFIG_MODULE_SIG=y $(builddir)/$*/.config; then \
				$(builddir)/$*/scripts/sign-file $(MODHASHALGO) \
					$(MODSECKEY) \
					$(MODPUBKEY) \
					$(pkgdir)/$$module; \
			fi; \
		fi; \
	done
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/build
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/source
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/modules.*
	rm -fr $(dbgpkgdir)/usr/lib/debug/lib/firmware
endif

	# The flavour specific headers image
	# TODO: Would be nice if we didn't have to dupe the original builddir
	install -d -m755 $(hdrdir)
	cat $(builddir)/$*/.config | \
		sed -e 's/.*CONFIG_DEBUG_INFO=.*/# CONFIG_DEBUG_INFO is not set/g' > \
		$(hdrdir)/.config
	chmod 644 $(hdrdir)/.config
	$(kmake) O=$(hdrdir) -j1 silentoldconfig prepare scripts
	# We'll symlink this stuff
	rm -f $(hdrdir)/Makefile
	rm -rf $(hdrdir)/include2 $(hdrdir)/source
	# Copy over the compilation version.
	cp "$(builddir)/$*/include/generated/compile.h" \
		"$(hdrdir)/include/generated/compile.h"
	# Add UTS_UBUNTU_RELEASE_ABI since UTS_RELEASE is difficult to parse.
	echo "#define UTS_UBUNTU_RELEASE_ABI $(abinum)" >> $(hdrdir)/include/generated/utsrelease.h
	# powerpc kernel arch seems to need some .o files for external module linking. Add them in.
ifeq ($(build_arch),powerpc)
	mkdir -p $(hdrdir)/arch/powerpc/lib
	cp $(builddir)/$*/arch/powerpc/lib/*.o $(hdrdir)/arch/powerpc/lib
endif
	# Script to symlink everything up
	$(SHELL) $(DROOT)/scripts/link-headers "$(hdrdir)" "$(indeppkg)" "$*"
	# The build symlink
	install -d $(stagedir)/$(basepkg)-$*/lib/modules/$(abi_release)-$*
	$(LN) /usr/src/$(basepkg)-$* \
		$(stagedir)/$(basepkg)-$*/lib/modules/$(abi_release)-$*/build
	# And finally the symvers
	install -m644 $(builddir)/$*/Module.symvers \
		$(hdrdir)/Module.symvers

	# Now the header scripts
	install -d $(stagedir)/$(basepkg)-$*/DEBIAN
	for script in postinst; do						\
	  sed -e 's/=V/$(abi_release)-$*/g' -e 's/=K/$(instfile)/g'	\
		$(DROOT)/control-scripts/headers-$$script > 			\
			$(stagedir)/$(basepkg)-$*/DEBIAN/$$script;		\
	  chmod 755 $(stagedir)/$(basepkg)-$*/DEBIAN/$$script;		\
	done

	# At the end of the package prep, call the tests
	DPKG_ARCH="$(arch)" KERN_ARCH="$(build_arch)" FLAVOUR="$*"	\
	 VERSION="$(abi_release)" REVISION="$(revision)"		\
	 PREV_REVISION="$(prev_revision)" ABI_NUM="$(abinum)"		\
	 PREV_ABI_NUM="$(prev_abinum)" BUILD_DIR="$(builddir)/$*"	\
	 INSTALL_DIR="$(pkgdir)" SOURCE_DIR="$(CURDIR)"			\
	 run-parts -v $(DROOT)/tests-build

	#
	# Remove files which are generated at installation by postinst,
	# except for modules.order and modules.builtin
	# 
	# NOTE: need to keep this list in sync with postrm
	#
	mkdir $(pkgdir)/lib/modules/$(abi_release)-$*/_
	mv $(pkgdir)/lib/modules/$(abi_release)-$*/modules.order \
		$(pkgdir)/lib/modules/$(abi_release)-$*/_
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin ] ; then \
	    mv $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin \
		$(pkgdir)/lib/modules/$(abi_release)-$*/_; \
	fi
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.*
	mv $(pkgdir)/lib/modules/$(abi_release)-$*/_/* \
		$(pkgdir)/lib/modules/$(abi_release)-$*
	rmdir $(pkgdir)/lib/modules/$(abi_release)-$*/_

ifeq ($(do_linux_tools),true)
	# Create the linux-tools tool links
	install -d $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
ifeq ($(do_tools_usbip),true)
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/usbip $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/usbipd $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
endif
ifeq ($(do_tools_cpupower),true)
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/cpupower $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
endif
ifeq ($(do_tools_perf),true)
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/perf $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
endif
ifeq ($(do_tools_x86),true)
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/x86_energy_perf_policy $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/turbostat $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
endif
endif
ifeq ($(do_cloud_tools),true)
ifeq ($(do_tools_hyperv),true)
	# Create the linux-hyperv tool links
	install -d $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/hv_kvp_daemon $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/hv_vss_daemon $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/hv_fcopy_daemon $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
	$(LN) ../../$(src_pkg_name)-tools-$(abi_release)/lsvmbus $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
endif
endif

headers_tmp := $(CURDIR)/debian/tmp-headers
headers_dir := $(stagedir)/linux-libc-dev

hmake := $(MAKE) -C $(CURDIR) O=$(headers_tmp) \
	KERNELVERSION=$(abi_release) INSTALL_HDR_PATH=$(headers_tmp)/install \
	SHELL="$(SHELL)" ARCH=$(header_arch)

install-arch-headers:
	@echo Debug: $@
	dh_testdir
	dh_testroot
	dh_clean -k -plinux-libc-dev

	rm -rf $(headers_tmp)
	install -d $(headers_tmp) $(headers_dir)/usr/include/

	$(hmake) $(defconfig)
	mv $(headers_tmp)/.config $(headers_tmp)/.config.old
	sed -e 's/^# \(CONFIG_MODVERSIONS\) is not set$$/\1=y/' \
	  -e 's/.*CONFIG_LOCALVERSION_AUTO.*/# CONFIG_LOCALVERSION_AUTO is not set/' \
	  $(headers_tmp)/.config.old > $(headers_tmp)/.config
	$(hmake) silentoldconfig
	$(hmake) headers_install

	( cd $(headers_tmp)/install/include/ && \
		find . -name '.' -o -name '.*' -prune -o -print | \
                cpio -pvd --preserve-modification-time \
			$(headers_dir)/usr/include/ )
	mkdir $(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)
	mv $(headers_dir)/usr/include/asm $(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)/

	rm -rf $(headers_tmp)

binary-arch-headers: install-arch-headers
	@echo Debug: $@
	dh_testdir
	dh_testroot
ifeq ($(do_libc_dev_package),true)
ifneq ($(DEBIAN),debian.master)
	echo "non-master branch building linux-libc-dev, aborting"
	exit 1
endif
	dh_installchangelogs -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	dh_installdocs -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	dh_compress -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	dh_fixperms -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	dh_installdeb -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	$(lockme) dh_gencontrol -P$(stagedir)/linux-libc-dev -plinux-libc-dev -- $(libc_dev_version)
	dh_md5sums -P$(stagedir)/linux-libc-dev -plinux-libc-dev
	dh_builddeb -P$(stagedir)/linux-libc-dev -plinux-libc-dev
endif

binary-%: pkgimg = $(bin_pkg_name)-$*
binary-%: pkgimg_ex = $(extra_pkg_name)-$*
binary-%: pkghdr = $(hdrs_pkg_name)-$*
binary-%: dbgpkg = $(bin_pkg_name)-$*-dbgsym
binary-%: dbgpkgdir = $(stagedir)/$(bin_pkg_name)-$*-dbgsym
binary-%: pkgtools = $(tools_flavour_pkg_name)-$*
binary-%: pkgcloud = $(cloud_flavour_pkg_name)-$*
binary-%: rprovides = $(if $(filter true,$(call custom_override,do_zfs,$*)),$(comma) spl-modules$(comma) spl-dkms$(comma) zfs-modules$(comma) zfs-dkms)
binary-%: target_flavour = $*
binary-%: install-%
	@echo Debug: $@
	dh_testdir
	dh_testroot

	dh_installchangelogs -P$(stagedir)/$(pkgimg) -p$(pkgimg)
	dh_installdocs -P$(stagedir)/$(pkgimg) -p$(pkgimg)
	dh_compress -P$(stagedir)/$(pkgimg) -p$(pkgimg)
	dh_fixperms -P$(stagedir)/$(pkgimg) -p$(pkgimg) -X/boot/
	dh_installdeb -P$(stagedir)/$(pkgimg) -p$(pkgimg)
	dh_shlibdeps -P$(stagedir)/$(pkgimg) -p$(pkgimg) $(shlibdeps_opts)
	$(lockme) dh_gencontrol -P$(stagedir)/$(pkgimg) -p$(pkgimg) -- -Vlinux:rprovides='$(rprovides)'
	dh_md5sums -P$(stagedir)/$(pkgimg) -p$(pkgimg)
	dh_builddeb -P$(stagedir)/$(pkgimg) -p$(pkgimg) -- -Zbzip2 -z9

ifeq ($(do_extras_package),true)
	if [ -f $(DEBIAN)/control.d/$(target_flavour).inclusion-list ] ; then \
		dh_installchangelogs -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_installdocs -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_compress -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_fixperms -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex) -X/boot/; \
		dh_installdeb -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_shlibdeps -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex) $(shlibdeps_opts); \
		$(lockme) dh_gencontrol -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_md5sums -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex); \
		dh_builddeb -P$(stagedir)/$(pkgimg_ex) -p$(pkgimg_ex) -- -Zbzip2 -z9; \
	fi
endif

	dh_installchangelogs -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_installdocs -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_compress -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_fixperms -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_shlibdeps -P$(stagedir)/$(pkghdr) -p$(pkghdr) $(shlibdeps_opts)
	dh_installdeb -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	$(lockme) dh_gencontrol -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_md5sums -P$(stagedir)/$(pkghdr) -p$(pkghdr)
	dh_builddeb -P$(stagedir)/$(pkghdr) -p$(pkghdr)

ifneq ($(skipsub),true)
	@set -e; for sub in $($(*)_sub); do		\
		pkg=$(bin_pkg_name)-$$sub;	\
		dh_installchangelogs -P$(stagedir)/$$pkg -p$$pkg;		\
		dh_installdocs -P$(stagedir)/$$pkg -p$$pkg;			\
		dh_compress -P$(stagedir)/$$pkg -p$$pkg;			\
		dh_fixperms -P$(stagedir)/$$pkg -p$$pkg -X/boot/;		\
		dh_shlibdeps -P$(stagedir)/$$pkg -p$$pkg $(shlibdeps_opts);	\
		dh_installdeb -P$(stagedir)/$$pkg -p$$pkg;			\
		$(lockme) dh_gencontrol -P$(stagedir)/$$pkg -p$$pkg;			\
		dh_md5sums -P$(stagedir)/$$pkg -p$$pkg;			\
		dh_builddeb -P$(stagedir)/$$pkg -p$$pkg;			\
	done
endif

ifneq ($(skipdbg),true)
	dh_installchangelogs -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_installdocs -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_compress -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_fixperms -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_installdeb -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	$(lockme) dh_gencontrol -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_md5sums -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)
	dh_builddeb -P$(stagedir)/$(dbgpkg) -p$(dbgpkg)

	# Hokay...here's where we do a little twiddling...
	# Renaming the debug package prevents it from getting into
	# the primary archive, and therefore prevents this very large
	# package from being mirrored. It is instead, through some
	# archive admin hackery, copied to http://ddebs.ubuntu.com.
	#
	mv ../$(dbgpkg)_$(release)-$(revision)_$(arch).deb \
		../$(dbgpkg)_$(release)-$(revision)_$(arch).ddeb
	set -e; \
	( \
		$(lockme_cmd) 9 || exit 1; \
		if grep -qs '^Build-Debug-Symbols: yes$$' /CurrentlyBuilding; then \
			sed -i '/^$(dbgpkg)_/s/\.deb /.ddeb /' debian/files; \
		else \
			grep -v '^$(dbgpkg)_.*$$' debian/files > debian/files.new; \
			mv debian/files.new debian/files; \
		fi; \
	) 9>$(lockme_file)
	# Now, the package wont get into the archive, but it will get put
	# into the debug system.
endif

ifeq ($(do_linux_tools),true)
	dh_installchangelogs -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_installdocs -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_compress -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_fixperms -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_shlibdeps -P$(stagedir)/$(pkgtools) -p$(pkgtools) $(shlibdeps_opts)
	dh_installdeb -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	$(lockme) dh_gencontrol -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_md5sums -P$(stagedir)/$(pkgtools) -p$(pkgtools)
	dh_builddeb -P$(stagedir)/$(pkgtools) -p$(pkgtools)
endif
ifeq ($(do_cloud_tools),true)
	dh_installchangelogs -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_installdocs -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_compress -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_fixperms -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_shlibdeps -P$(stagedir)/$(pkgcloud) -p$(pkgcloud) $(shlibdeps_opts)
	dh_installdeb -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	$(lockme) dh_gencontrol -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_md5sums -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
	dh_builddeb -P$(stagedir)/$(pkgcloud) -p$(pkgcloud)
endif

ifneq ($(full_build),false)
	# Clean out this flavours build directory.
	rm -rf $(builddir)/$*
	# Clean out the debugging package source directory.
	rm -rf $(dbgpkgdir)
endif

#
# per-architecture packages
#
builddirpa = $(builddir)/tools-perarch

$(stampdir)/stamp-prepare-perarch:
	@echo Debug: $@
ifeq ($(do_any_tools),true)
	rm -rf $(builddirpa)
	install -d $(builddirpa)
	rsync -a --exclude debian --exclude debian.master --exclude $(DEBIAN) --exclude .git -a ./ $(builddirpa)/
endif
	mkdir -p $(stampdir)
	touch $@

$(stampdir)/stamp-build-perarch: $(stampdir)/stamp-prepare-perarch install-arch-headers
	@echo Debug: $@
ifeq ($(do_linux_tools),true)
ifeq ($(do_tools_usbip),true)
	chmod 755 $(builddirpa)/tools/usb/usbip/autogen.sh
	cd $(builddirpa)/tools/usb/usbip && ./autogen.sh
	chmod 755 $(builddirpa)/tools/usb/usbip/configure
	cd $(builddirpa)/tools/usb/usbip && ./configure --prefix=$(builddirpa)/tools/usb/usbip/bin
	cd $(builddirpa)/tools/usb/usbip && make install CFLAGS="-g -O2 -static" CROSS_COMPILE=$(CROSS_COMPILE)
endif
ifeq ($(do_tools_cpupower),true)
	# Allow for multiple installed versions of cpupower and libcpupower.so:
	# Override LIB_MIN in order to to generate a versioned .so named
	# libcpupower.so.$(abi_release) and link cpupower with that.
	make -C $(builddirpa)/tools/power/cpupower \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		CROSS=$(CROSS_COMPILE) \
		LIB_MIN=$(abi_release) CPUFREQ_BENCH=false
endif
ifeq ($(do_tools_perf),true)
	cd $(builddirpa) && $(kmake) $(defconfig)
	mv $(builddirpa)/.config $(builddirpa)/.config.old
	sed -e 's/^# \(CONFIG_MODVERSIONS\) is not set$$/\1=y/' \
	  -e 's/.*CONFIG_LOCALVERSION_AUTO.*/# CONFIG_LOCALVERSION_AUTO is not set/' \
	  $(builddirpa)/.config.old > $(builddirpa)/.config
	cd $(builddirpa) && $(kmake) silentoldconfig
	cd $(builddirpa) && $(kmake) prepare
	cd $(builddirpa)/tools/perf && \
		$(kmake) prefix=/usr HAVE_CPLUS_DEMANGLE=1 CROSS_COMPILE=$(CROSS_COMPILE) NO_LIBPYTHON=1 NO_LIBPERL=1 PYTHON=python2.7
endif
ifeq ($(do_tools_x86),true)
	cd $(builddirpa)/tools/power/x86/x86_energy_perf_policy && make CROSS_COMPILE=$(CROSS_COMPILE)
	cd $(builddirpa)/tools/power/x86/turbostat && make CROSS_COMPILE=$(CROSS_COMPILE)
endif
endif
ifeq ($(do_cloud_tools),true)
ifeq ($(do_tools_hyperv),true)
	cd $(builddirpa)/tools/hv && make CFLAGS="-I$(headers_dir)/usr/include -I$(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)" CROSS_COMPILE=$(CROSS_COMPILE) hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon
endif
endif
	@mkdir -p $(stampdir)
	@touch $@

install-perarch: toolspkgdir = $(stagedir)/$(tools_pkg_name)
install-perarch: cloudpkgdir = $(stagedir)/$(cloud_pkg_name)
install-perarch: $(stampdir)/stamp-build-perarch
	@echo Debug: $@
	# Add the tools.
ifeq ($(do_linux_tools),true)
	install -d $(toolspkgdir)/usr/lib
	install -d $(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
ifeq ($(do_tools_usbip),true)
	install -m755 $(builddirpa)/tools/usb/usbip/bin/sbin/usbip \
		$(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/usb/usbip/bin/sbin/usbipd \
		$(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
endif
ifeq ($(do_tools_cpupower),true)
	install -m755 $(builddirpa)/tools/power/cpupower/cpupower \
		$(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	# Install only the full versioned libcpupower.so.$(abi_release), not
	# the usual symlinks to it.
	install -m644 $(builddirpa)/tools/power/cpupower/libcpupower.so.$(abi_release) \
		$(toolspkgdir)/usr/lib/
endif
ifeq ($(do_tools_perf),true)
	install -m755 $(builddirpa)/tools/perf/perf $(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
endif
ifeq ($(do_tools_x86),true)
	install -m755 $(builddirpa)/tools/power/x86/x86_energy_perf_policy/x86_energy_perf_policy \
		$(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/power/x86/turbostat/turbostat \
		$(toolspkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
endif
endif
ifeq ($(do_cloud_tools),true)
ifeq ($(do_tools_hyperv),true)
	install -d $(cloudpkgdir)/usr/lib
	install -d $(cloudpkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/hv/hv_kvp_daemon \
		$(cloudpkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/hv/hv_vss_daemon \
		$(cloudpkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/hv/hv_fcopy_daemon \
		$(cloudpkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
	install -m755 $(builddirpa)/tools/hv/lsvmbus \
		$(cloudpkgdir)/usr/lib/$(src_pkg_name)-tools-$(abi_release)
endif
endif

binary-perarch: toolspkg = $(tools_pkg_name)
binary-perarch: cloudpkg = $(cloud_pkg_name)
binary-perarch: install-perarch
	@echo Debug: $@
ifeq ($(do_linux_tools),true)
	dh_strip -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_installchangelogs -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_installdocs -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_compress -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_fixperms -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_shlibdeps -P$(stagedir)/$(toolspkg) -p$(toolspkg) $(shlibdeps_opts)
	dh_installdeb -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	$(lockme) dh_gencontrol -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_md5sums -P$(stagedir)/$(toolspkg) -p$(toolspkg)
	dh_builddeb -P$(stagedir)/$(toolspkg) -p$(toolspkg)
endif
ifeq ($(do_cloud_tools),true)
	dh_strip-P$(stagedir)/$(cloudpkg)  -p$(cloudpkg)
	dh_installchangelogs -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_installdocs -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_compress -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_fixperms -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_shlibdeps -P$(stagedir)/$(cloudpkg) -p$(cloudpkg) $(shlibdeps_opts)
	dh_installdeb -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	$(lockme) dh_gencontrol -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_md5sums -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
	dh_builddeb -P$(stagedir)/$(cloudpkg) -p$(cloudpkg)
endif

binary-debs: signed = $(stagedir)/$(bin_pkg_name)-signed
binary-debs: signedv = $(stagedir)/$(bin_pkg_name)-signed/$(release)-$(revision)
binary-debs: signed_tar = $(src_pkg_name)_$(release)-$(revision)_$(arch).tar.gz
binary-debs: binary-perarch $(addprefix binary-,$(flavours))
	@echo Debug: $@
ifeq ($(uefi_signed),true)
	echo $(release)-$(revision) > $(signedv)/version
	cd $(signedv) && ls *.efi >flavours
	cd $(signed) && tar czvf ../../../$(signed_tar) .
	dpkg-distaddfile $(signed_tar) raw-uefi -
endif

build-arch-deps-$(do_flavour_image_package) += $(addprefix $(stampdir)/stamp-build-,$(flavours))
build-arch: $(build-arch-deps-true)
	@echo Debug: $@

ifneq ($(do_common_headers_indep),true)
binary-arch-deps-$(do_flavour_header_package) += binary-headers
endif
ifeq ($(AUTOBUILD),)
binary-arch-deps-$(do_flavour_image_package) += binary-udebs
else
binary-arch-deps-$(do_flavour_image_package) += binary-debs
endif
binary-arch-deps-$(do_libc_dev_package) += binary-arch-headers

binary-arch: $(binary-arch-deps-true)
	@echo Debug: $@
