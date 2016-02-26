#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

copy_overlay(){
	msg2 "Copying [%s] ..." "${1##*/}"
	if [[ -L $1 ]];then
		cp -a --no-preserve=ownership $1/* $2
	else
		cp -LR $1/* $2
	fi
}

write_profile_conf_entries(){
	local conf=$1/profile.conf
	echo '' >> ${conf}
	echo '# profile image name' >> ${conf}
	echo "profile=${profile}" >> ${conf}
	echo '' >> ${conf}
	echo '# iso_name' >> ${conf}
	echo "iso_name=${iso_name}" >> ${conf}
}

copy_profile_conf(){
	msg2 "Copying profile.conf ..."
	[[ ! -d $1 ]] && mkdir -p $1

	cp ${profile_conf} $1

	write_profile_conf_entries $1
}

copy_cache_mhwd(){
	msg2 "Copying mhwd package cache ..."
	rsync -v --files-from="$1/cache-packages.txt" /var/cache/pacman/pkg "$1/opt/live/pkgs"
}

gen_pw(){
	echo $(perl -e 'print crypt($ARGV[0], "password")' ${password})
}

# $1: chroot
configure_user(){
	# set up user and password
	msg2 "Creating user: [%s] password: [%s] ..." "${username}" "${password}"
	if [[ -n ${password} ]];then
		chroot $1 useradd -m -G ${addgroups} -p $(gen_pw) ${username}
	else
		chroot $1 useradd -m -G ${addgroups} ${username}
	fi
}

# $1: chroot
configure_hosts(){
	sed -e "s|localhost.localdomain|localhost.localdomain ${hostname}|" -i $1/etc/hosts
}

add_svc_rc(){
	if [[ -f $1/etc/init.d/$2 ]];then
		msg2 "Setting %s ..." "$2"
		chroot $1 rc-update add $2 default &>/dev/null
	fi
}

add_svc_sd(){
	if [[ -f $1/etc/systemd/system/$2.service ]] || \
	[[ -f $1/usr/lib/systemd/system/$2.service ]];then
		msg2 "Setting %s ..." "$2"
		chroot $1 systemctl enable $2 &>/dev/null
	fi
}
# $1: chroot
configure_environment(){
	case ${profile} in
		cinnamon*|gnome|i3|lxde|mate|netbook|openbox|pantheon|xfce*)
			echo "QT_STYLE_OVERRIDE=gtk" >> $1/etc/environment
		;;
	esac
}

# $1: chroot
# $2: user
configure_accountsservice(){
	msg2 "Configuring Accountsservice ..."
	local path=$1/var/lib/AccountsService/users
	if [ -d "${path}" ] ; then
		echo "[User]" > ${path}/$2
		echo "XSession=${default_desktop_file}" >> ${path}/$2
		echo "Icon=/var/lib/AccountsService/icons/$2.png" >> ${path}/$2
	fi
}

load_desktop_map(){
	local _space="s| ||g" _clean=':a;N;$!ba;s/\n/ /g' _com_rm="s|#.*||g" \
		file=${DATADIR}/desktop.map
	local desktop_map=$(sed "$_com_rm" "$file" \
			| sed "$_space" \
			| sed "$_clean")
        echo ${desktop_map}
}

detect_desktop_env(){
	local xs=$1/usr/share/xsessions ex=$1/usr/bin key val map=( $(load_desktop_map) )
	default_desktop_file="none"
	default_desktop_executable="none"
	msg2 "Trying to detect desktop environment ..."
	for item in "${map[@]}";do
		key=${item%:*}
		val=${item#*:}
		if [[ -f $xs/$key.desktop ]] && [[ -f $ex/$val ]];then
			default_desktop_file="$key"
			default_desktop_executable="$val"
		fi
	done
	msg2 "Detected: %s" "${default_desktop_file}"
}

set_xdm(){
	if [[ -f $1/etc/conf.d/xdm ]];then
		local conf='DISPLAYMANAGER="'${displaymanager}'"'
		sed -i -e "s|^.*DISPLAYMANAGER=.*|${conf}|" $1/etc/conf.d/xdm
	fi
}

# $1: chroot
configure_displaymanager(){
	msg2 "Configuring Displaymanager ..."
	# Try to detect desktop environment
	detect_desktop_env "$1"
	# Configure display manager
	case ${displaymanager} in
		'lightdm')
			chroot $1 groupadd -r autologin
			local conf=$1/etc/lightdm/lightdm.conf
			if [[ ${default_desktop_executable} != "none" ]] && [[ ${default_desktop_file} != "none" ]]; then
				sed -i -e "s/^.*user-session=.*/user-session=$default_desktop_file/" ${conf}
			fi
			if [[ ${initsys} == 'openrc' ]];then
				sed -i -e 's/^.*minimum-vt=.*/minimum-vt=7/' ${conf}
				sed -i -e 's/pam_systemd.so/pam_ck_connector.so nox11/' $1/etc/pam.d/lightdm-greeter
			fi
			local greeters=$(ls $1/usr/share/xgreeters/*greeter.desktop) name
			for g in ${greeters[@]};do
				name=${g##*/}
				name=${name%%.*}
				case ${name} in
					'lightdm-deepin-greeter'|'lightdm-kde-greeter')
						sed -i -e "s/^.*greeter-session=.*/greeter-session=${name}/" ${conf}
					;;
				esac
			done
		;;
		'gdm')
			configure_accountsservice $1 "gdm"
		;;
		'mdm')
			local conf=$1/etc/mdm/custom.conf
			if [[ ${default_desktop_executable} != "none" ]] && [[ ${default_desktop_file} != "none" ]]; then
				sed -i "s|default.desktop|$default_desktop_file.desktop|g" ${conf}
			fi
		;;
		'sddm')
			local conf=$1/etc/sddm.conf
			if [[ ${default_desktop_executable} != "none" ]] && [[ ${default_desktop_file} != "none" ]]; then
				sed -i -e "s|^Session=.*|Session=$default_desktop_file.desktop|" ${conf}
			fi
			if [[ ${initsys} == 'openrc' ]];then
				local halt='/usr/bin/shutdown -h -P now' \
					reboot='/usr/bin/shutdown -r now'
				sed -e "s|^.*HaltCommand=.*|HaltCommand=${halt}|" \
					-e "s|^.*RebootCommand=.*|RebootCommand=${reboot}|" \
					-e "s|^.*MinimumVT=.*|MinimumVT=7|" \
					-i ${conf}
			fi
		;;
		'lxdm')
			local conf=$1/etc/lxdm/lxdm.conf
			if [[ ${default_desktop_executable} != "none" ]] && [[ ${default_desktop_file} != "none" ]]; then
				sed -i -e "s|^.*session=.*|session=/usr/bin/$default_desktop_executable|" ${conf}
			fi
		;;
	esac
	msg2 "Configured: ${displaymanager}"
}

# $1: chroot
configure_mhwd_drivers(){
	local path=$1/opt/live/pkgs/ \
		drv_path=$1/var/lib/mhwd/db/pci/graphic_drivers
	if  [ -z "$(ls $path | grep catalyst-utils 2> /dev/null)" ]; then
		msg2 "Disabling Catalyst driver"
		mkdir -p $drv_path/catalyst/
		touch $drv_path/catalyst/MHWDCONFIG
	fi
	if  [ -z "$(ls $path | grep nvidia-utils 2> /dev/null)" ]; then
		msg2 "Disabling Nvidia driver"
		mkdir -p $drv_path/nvidia/
		touch $drv_path/nvidia/MHWDCONFIG
		msg2 "Disabling Nvidia Bumblebee driver"
		mkdir -p $drv_path/hybrid-intel-nvidia-bumblebee/
		touch $drv_path/hybrid-intel-nvidia-bumblebee/MHWDCONFIG
	fi
	if  [ -z "$(ls $path | grep nvidia-304xx-utils 2> /dev/null)" ]; then
		msg2 "Disabling Nvidia 304xx driver"
		mkdir -p $drv_path/nvidia-304xx/
		touch $drv_path/nvidia-304xx/MHWDCONFIG
	fi
	if  [ -z "$(ls $path | grep nvidia-340xx-utils 2> /dev/null)" ]; then
		msg2 "Disabling Nvidia 340xx driver"
		mkdir -p $drv_path/nvidia-340xx/
		touch $drv_path/nvidia-340xx/MHWDCONFIG
	fi
	if  [ -z "$(ls $path | grep xf86-video-amdgpu 2> /dev/null)" ]; then
		msg2 "Disabling AMD gpu driver"
		mkdir -p $drv_path/xf86-video-amdgpu/
		touch $drv_path/xf86-video-amdgpu/MHWDCONFIG
	fi
}

chroot_clean(){
	msg "Cleaning up ..."
	for image in "$1"/*-image; do
		[[ -d ${image} ]] || continue
		local name=${image##*/}
		if [[ $name != "mhwd-image" ]];then
			msg2 "Deleting chroot [%s] ..." "$name"
			lock 9 "${image}.lock" "Locking chroot '${image}'"
			if [[ "$(stat -f -c %T "${image}")" == btrfs ]]; then
				{ type -P btrfs && btrfs subvolume delete "${image}"; } #&> /dev/null
			fi
		rm -rf --one-file-system "${image}"
		fi
	done
	exec 9>&-
	rm -rf --one-file-system "$1"
}

# Remove pamac auto-update when the network is up, it locks de pacman db when booting in the livecd
# $1: chroot
configure_pamac_live() {
	if [[ -f $1/etc/NetworkManager/dispatcher.d/99_update_pamac_tray ]];then
		rm -f $1/etc/NetworkManager/dispatcher.d/99_update_pamac_tray
	fi
}

# $1: chroot
configure_lsb(){
	[[ -f $1/boot/grub/grub.cfg ]] && rm $1/boot/grub/grub.cfg
	if [ -e $1/etc/lsb-release ] ; then
		msg2 "Configuring lsb-release"
		sed -i -e "s/^.*DISTRIB_RELEASE.*/DISTRIB_RELEASE=${dist_release}/" $1/etc/lsb-release
		sed -i -e "s/^.*DISTRIB_CODENAME.*/DISTRIB_CODENAME=${dist_codename}/" $1/etc/lsb-release
	fi
}

configure_mhwd(){
	if [[ ${arch} == "x86_64" ]];then
		if ! ${multilib};then
			msg2 "Disable mhwd lib32 support"
			echo 'MHWD64_IS_LIB32="false"' > $1/etc/mhwd-x86_64.conf
		fi
	fi
}

configure_systemd(){
	if [[ ${initsys} == 'systemd' ]];then
		msg2 "Configuring logind"
		local conf=$1/etc/systemd/logind.conf
		sed -i 's/#\(HandleSuspendKey=\)suspend/\1ignore/' "$conf"
		sed -i 's/#\(HandleLidSwitch=\)suspend/\1ignore/' "$conf"
	fi
}

# $1: chroot
configure_systemd_live(){
	if [[ ${initsys} == 'systemd' ]];then
		msg2 "Configuring systemd for live session"
		sed -i 's/#\(Storage=\)auto/\1volatile/' $1/etc/systemd/journald.conf
		#sed -i 's/#\(HandleSuspendKey=\)suspend/\1ignore/' $1/etc/systemd/logind.conf
		sed -i 's/#\(HandleHibernateKey=\)hibernate/\1ignore/' $1/etc/systemd/logind.conf
		#sed -i 's/#\(HandleLidSwitch=\)suspend/\1ignore/' $1/etc/systemd/logind.conf
		# Prevent some services to be started in the livecd
		echo 'File created by manjaro-tools. See systemd-update-done.service(8).' \
		     | tee "${path}/etc/.updated" >"${path}/var/.updated"

		msg2 "Setting hostname: %s ..." "${hostname}"
		echo ${hostname} > $1/etc/hostname
	fi
}

configure_openrc(){
	if [[ ${initsys} == 'openrc' ]];then
		msg2 "Configuring sysctl for openrc"
		touch $1/etc/sysctl.conf
		local conf=$1/etc/sysctl.d/100-manjaro.conf
		echo '# Virtual memory setting (swap file or partition)' > ${conf}
		echo 'vm.swappiness = 30' >> ${conf}
		echo '# Enable the SysRq key' >> ${conf}
		echo 'kernel.sysrq = 1' >> ${conf}

		rm $1/etc/runlevels/boot/hwclock
	fi
}

# $1: chroot
configure_openrc_live(){
	if [[ ${initsys} == 'openrc' ]];then
		msg2 "Setting hostname: %s ..." "${hostname}"
		local _hostname='hostname="'${hostname}'"'
		sed -i -e "s|^.*hostname=.*|${_hostname}|" $1/etc/conf.d/hostname
	fi
}

configure_services(){
	info "Configuring [%s]" "${initsys}"
	case ${initsys} in
		'openrc')
			for svc in ${start_openrc[@]}; do
				add_svc_rc "$1" "$svc"
			done
			if [[ ${displaymanager} != "none" ]];then
				set_xdm "$1"
				add_svc_rc "$1" "xdm"
			fi
		;;
		'systemd')
			for svc in ${start_systemd[@]}; do
				add_svc_sd "$1" "$svc"
			done
			if [[ ${displaymanager} != "none" ]];then
				local service=${displaymanager}
				if ${plymouth_boot}; then
					#msg2 "Setting plymouth %s ...." "${plymouth_theme}"
					sed -i -e "s/^.*Theme=.*/Theme=${plymouth_theme}/" $1/etc/plymouth/plymouthd.conf
					if [[ -f $1/etc/systemd/system/${displaymanager}-plymouth.service ]] || \
					[[ -f $1/usr/lib/systemd/system/${displaymanager}-plymouth.service ]];then
						service=${displaymanager}-plymouth
					fi
				fi
				add_svc_sd "$1" "$service"
			fi
		;;
	esac
	info "Done configuring [%s]" "${initsys}"
}

configure_services_live(){
	info "Configuring [%s]" "${initsys}"
	case ${initsys} in
		'openrc')
			for svc in ${start_openrc_live[@]}; do
				add_svc_rc "$1" "$svc"
			done
		;;
		'systemd')
			for svc in ${start_systemd_live[@]}; do
				add_svc_sd "$1" "$svc"
			done
		;;
	esac
	info "Done configuring [%s]" "${initsys}"
}

configure_root_image(){
	msg "Configuring [root-image]"
	configure_lsb "$1"
	configure_mhwd "$1"
	configure_openrc "$1"
	configure_systemd "$1"
	msg "Done configuring [root-image]"
}

configure_custom_image(){
	msg "Configuring [%s-image]" "${profile}"
	configure_displaymanager "$1"
	configure_services "$1"
	configure_environment "$1"
	msg "Done configuring [%s-image]" "${profile}"
}

configure_live_image(){
	msg "Configuring [live-image]"
	configure_hosts "$1"
	configure_user "$1"
	configure_accountsservice "$1" "${username}"
	configure_services_live "$1"
	configure_systemd_live "$1"
	configure_openrc_live "$1"
	configure_calamares "$1"
	configure_thus "$1"
	configure_pamac_live "$1"
	msg "Done configuring [live-image]"
}

make_repo(){
	repo-add $1/opt/live/pkgs/gfx-pkgs.db.tar.gz $1/opt/live/pkgs/*pkg*z
}

# $1: work dir
# $2: pkglist
download_to_cache(){
	chroot-run \
		  -r "${mountargs_ro}" \
		  -w "${mountargs_rw}" \
		  -B "${build_mirror}/${branch}" \
		  "$1" \
		  pacman -v -Syw $2 --noconfirm || return 1
	chroot-run \
		  -r "${mountargs_ro}" \
		  -w "${mountargs_rw}" \
		  -B "${build_mirror}/${branch}" \
		  "$1" \
		  pacman -v -Sp $2 --noconfirm > "$1"/cache-packages.txt
	sed -ni '/.pkg.tar.xz/p' "$1"/cache-packages.txt
	sed -i "s/.*\///" "$1"/cache-packages.txt
}

# $1: image path
# $2: packages
chroot_create(){
	[[ "$1" == "${work_dir}/root-image" ]] && local flag="-L"
	setarch "${arch}" \
		mkchroot ${mkchroot_args[*]} ${flag} $@
}

# $1: image path
clean_up_image(){
	msg2 "Cleaning up [%s]" "${1##*/}"
	[[ -d "$1/boot/" ]] && find "$1/boot" -name 'initramfs*.img' -delete #&> /dev/null
	[[ -f "$1/etc/locale.gen.bak" ]] && mv "$1/etc/locale.gen.bak" "$1/etc/locale.gen"
	[[ -f "$1/etc/locale.conf.bak" ]] && mv "$1/etc/locale.conf.bak" "$1/etc/locale.conf"

	find "$1/var/lib/pacman" -maxdepth 1 -type f -delete #&> /dev/null
	find "$1/var/lib/pacman/sync" -type f -delete #&> /dev/null
	#find "$1/var/cache/pacman/pkg" -type f -delete &> /dev/null
	find "$1/var/log" -type f -delete #&> /dev/null
	#find "$1/var/tmp" -mindepth 1 -delete &> /dev/null
	#find "$1/tmp" -mindepth 1 -delete &> /dev/null

# 	find "${work_dir}" -name *.pacnew -name *.pacsave -name *.pacorig -delete
}

clean_up_mhwd_image(){
	msg2 "Cleaning up [%s]" "${1##*/}"
	rm -r $1/var
	rm -rf "$1/etc"
	rm -f "$1/cache-packages.txt"
}
