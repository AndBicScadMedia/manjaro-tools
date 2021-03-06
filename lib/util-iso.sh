#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

import ${LIBDIR}/util-iso-image.sh
import ${LIBDIR}/util-iso-boot.sh
import ${LIBDIR}/util-yaml.sh

error_function() {
    if [[ -p $logpipe ]]; then
        rm "$logpipe"
    fi
    # first exit all subshells, then print the error
    if (( ! BASH_SUBSHELL )); then
        error "A failure occurred in %s()." "$1"
        plain "Aborting..."
    fi
    umount_image
    exit 2
}

# $1: function
run_log(){
    local func="$1"
    local tmpfile=${tmp_dir}/$func.ansi.log logfile=${log_dir}/$(gen_iso_fn).$func.log
    logpipe=$(mktemp -u "${tmp_dir}/$func.pipe.XXXXXXXX")
    mkfifo "$logpipe"
    tee "$tmpfile" < "$logpipe" &
    local teepid=$!
    $func &> "$logpipe"
    wait $teepid
    rm "$logpipe"
    cat $tmpfile | perl -pe 's/\e\[?.*?[\@-~]//g' > $logfile
    rm "$tmpfile"
}

run_safe() {
    local restoretrap func="$1"
    set -e
    set -E
    restoretrap=$(trap -p ERR)
    trap 'error_function $func' ERR

    if ${verbose};then
        run_log "$func"
    else
        "$func"
    fi

    eval $restoretrap
    set +E
    set +e
}

trap_exit() {
    local sig=$1; shift
    error "$@"
    umount_image
    trap -- "$sig"
    kill "-$sig" "$$"
}

# $1: image path
make_sqfs() {
    if [[ ! -d "$1" ]]; then
        error "$1 is not a directory"
        return 1
    fi
    local timer=$(get_timer) path=${work_dir}/iso/${iso_name}/${target_arch}
    local name=${1##*/}
    local sq_img="${path}/$name.sqfs"
    mkdir -p ${path}
    msg "Generating SquashFS image for %s" "${1}"
    if [[ -f "${sq_img}" ]]; then
        local has_changed_dir=$(find ${1} -newer ${sq_img})
        msg2 "Possible changes for %s ..." "${1}"  >> ${tmp_dir}/buildiso.debug
        msg2 "%s" "${has_changed_dir}" >> ${tmp_dir}/buildiso.debug
        if [[ -n "${has_changed_dir}" ]]; then
            msg2 "SquashFS image %s is not up to date, rebuilding..." "${sq_img}"
            rm "${sq_img}"
        else
            msg2 "SquashFS image %s is up to date, skipping." "${sq_img}"
            return
        fi
    fi

    msg2 "Creating SquashFS image. This may take some time..."
    local used_kernel=${kernel:5:1} mksqfs_args=(${1} ${sq_img} -noappend)
    local highcomp="-b 256K -Xbcj x86"
    [[ "${iso_compression}" != "xz" ]] && highcomp=""

    if [[ "$name" == "mhwd-image" && ${used_kernel} < "4" ]]; then
        mksqfs_args+=(-comp lz4)
        if ${verbose};then
            mksquashfs "${mksqfs_args[@]}" >/dev/null
        else
            mksquashfs "${mksqfs_args[@]}"
        fi
    else
        mksqfs_args+=(-comp ${iso_compression} ${highcomp})
        if ${verbose};then
            mksquashfs "${mksqfs_args[@]}" >/dev/null
        else
            mksquashfs "${mksqfs_args[@]}"
        fi
    fi

    show_elapsed_time "${FUNCNAME}" "${timer_start}"
}

assemble_iso(){
    msg "Creating ISO image..."
    local efi_boot_args=()
    if [[ -f "${work_dir}/iso/EFI/miso/${iso_name}.img" ]]; then
        msg2 "Setting efi args. El Torito detected."
        efi_boot_args=("-eltorito-alt-boot"
                "-e EFI/miso/${iso_name}.img"
                "-isohybrid-gpt-basdat"
                "-no-emul-boot")
    fi

    xorriso -as mkisofs \
        -iso-level 3 -rock -joliet \
        -max-iso9660-filenames -omit-period \
        -omit-version-number \
        -relaxed-filenames -allow-lowercase \
        -volid "${iso_label}" \
        -appid "${iso_app_id}" \
        -publisher "${iso_publisher}" \
        -preparer "Prepared by manjaro-tools/${0##*/}" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${work_dir}/iso/isolinux/isohdpfx.bin" \
        ${efi_boot_args[@]} \
        -output "${iso_dir}/${iso_file}" \
        "${work_dir}/iso/"
}

# Build ISO
make_iso() {
    msg "Start [Build ISO]"
    touch "${work_dir}/iso/.miso"
    for d in $(find "${work_dir}" -maxdepth 1 -type d -name '[^.]*'); do
        if [[ "$d" != "${work_dir}/iso" ]] && \
        [[ "${d##*/}" != "iso" ]] && \
        [[ "${d##*/}" != "efiboot" ]] && \
        [[ "$d" != "${work_dir}" ]]; then
            make_sqfs "$d"
        fi
    done

    msg "Making bootable image"
    # Sanity checks
    [[ ! -d "${work_dir}/iso" ]] && return 1
    if [[ -f "${iso_dir}/${iso_file}" ]]; then
        msg2 "Removing existing bootable image..."
        rm -rf "${iso_dir}/${iso_file}"
    fi
    assemble_iso
    msg "Done [Build ISO]"
}

gen_iso_fn(){
    local vars=() name
    vars+=("${iso_name}")
    if ! ${netinstall};then
        [[ -n ${profile} ]] && vars+=("${profile}")
    else
        if ${unpackfs};then
            [[ -n ${profile} ]] && vars+=("${profile}")
        fi
    fi
    [[ ${initsys} == 'openrc' ]] && vars+=("${initsys}")
    vars+=("${dist_release}")
    vars+=("${target_branch}")
    vars+=("${target_arch}")
    for n in ${vars[@]};do
        name=${name:-}${name:+-}${n}
    done
    echo $name
}

reset_pac_conf(){
    info "Restoring [%s/etc/pacman.conf] ..." "$1"
    sed -e 's|^.*HoldPkg.*|HoldPkg      = pacman glibc manjaro-system|' \
        -e "s|^.*#CheckSpace|CheckSpace|" \
        -i "$1/etc/pacman.conf"
}

# Base installation (root-image)
make_image_root() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Base installation] (root-image)"
        local path="${work_dir}/root-image"
        mkdir -p ${path}

        chroot_create "${path}" "${packages}" || die

        pacman -Qr "${path}" > "${path}/root-image-pkgs.txt"
        copy_overlay "${profile_dir}/root-overlay" "${path}"

        reset_pac_conf "${path}"

        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Base installation] (root-image)"
    fi
}

make_image_custom() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Desktop installation] (%s-image)" "${profile}"
        local path="${work_dir}/${profile}-image"
        mkdir -p ${path}

        mount_image "${path}"

        chroot_create "${path}" "${packages}"

        pacman -Qr "${path}" > "${path}/${profile}-image-pkgs.txt"
        cp "${path}/${profile}-image-pkgs.txt" ${iso_dir}/$(gen_iso_fn)-pkgs.txt
        [[ -e ${profile_dir}/${profile}-overlay ]] && copy_overlay "${profile_dir}/${profile}-overlay" "${path}"

        reset_pac_conf "${path}"

        umount_image
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Desktop installation] (%s-image)" "${profile}"
    fi
}

mount_image_select(){
    if [[ -f "${packages_custom}" ]]; then
        mount_image_custom "$1"
    else
        mount_image "$1"
    fi
}

configure_live_image(){
    msg "Configuring [live-image]"
    detect_desktop_env "$1"
    configure_hosts "$1"
    configure_lsb "$1"
    configure_mhwd "$1"
    configure_system "$1"
    configure_services "$1"
    configure_calamares "$1"
    write_live_session_conf "$1"
    msg "Done configuring [live-image]"
}

make_image_live() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Live installation] (live-image)"
        local path="${work_dir}/live-image"
        mkdir -p ${path}

        mount_image_select "${path}"

        chroot_create "${path}" "${packages}"

        pacman -Qr "${path}" > "${path}/live-image-pkgs.txt"
        copy_overlay "${profile_dir}/live-overlay" "${path}"
        configure_live_image "${path}"

        reset_pac_conf "${path}"

        umount_image

        # Clean up GnuPG keys
        rm -rf "${path}/etc/pacman.d/gnupg"
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Live installation] (live-image)"
    fi
}

make_image_mhwd() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [drivers repository] (mhwd-image)"
        local path="${work_dir}/mhwd-image"
        mkdir -p ${path}${mhwd_repo}

        mount_image_select "${path}"

        reset_pac_conf "${path}"

        copy_from_cache "${path}" "${packages}"

        if [[ -n "${packages_cleanup}" ]]; then
            for mhwd_clean in ${packages_cleanup}; do
                rm ${path}${mhwd_repo}/${mhwd_clean}
            done
        fi
        cp ${DATADIR}/pacman-mhwd.conf ${path}/opt
        make_repo "${path}"
        configure_mhwd_drivers "${path}"

        umount_image
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [drivers repository] (mhwd-image)"
    fi
}

make_image_boot() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [%s/boot]" "${iso_name}"
        local path_iso="${work_dir}/iso/${iso_name}/boot"
        mkdir -p ${path_iso}/${target_arch}
        cp ${work_dir}/root-image/boot/memtest86+/memtest.bin ${path_iso}/${target_arch}/memtest
        cp ${work_dir}/root-image/boot/vmlinuz* ${path_iso}/${target_arch}/${iso_name}
        local path="${work_dir}/boot-image"
        mkdir -p ${path}

        mount_image_select "${path}"
        configure_plymouth "${path}"

        copy_initcpio "${profile_dir}" "${path}"

        gen_boot_image "${path}"

        mv ${path}/boot/${iso_name}.img ${path_iso}/${target_arch}/${iso_name}.img
        [[ -f ${path}/boot/intel-ucode.img ]] && copy_ucode "${path}" "${path_iso}"

        umount_image

        rm -R ${path}
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [%s/boot]" "${iso_name}"
    fi
}

# Prepare /EFI
make_efi() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [%s/boot/EFI]" "${iso_name}"
        local path_iso="${work_dir}/iso"
        local path_efi="${path_iso}/EFI"
        mkdir -p ${path_efi}/boot
        copy_efi_loaders "${work_dir}/root-image" "${path_efi}/boot"
        mkdir -p ${path_iso}/loader/entries
        write_loader_conf "${path_iso}/loader"
        write_efi_shellv1_conf "${path_iso}/loader/entries"
        write_efi_shellv2_conf "${path_iso}/loader/entries"
        write_usb_conf "${path_iso}/loader/entries" "${path_iso}"
        write_usb_nonfree_conf "${path_iso}/loader/entries" "${path_iso}"
        copy_efi_shells "${path_efi}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [%s/boot/EFI]" "${iso_name}"
    fi
}

# Prepare kernel.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [%s/iso/EFI]" "${iso_name}"
        local path_iso="${work_dir}/iso" size="31M"
        mkdir -p ${path_iso}/EFI/miso
        truncate -s ${size} ${path_iso}/EFI/miso/${iso_name}.img
        mkfs.fat -n MISO_EFI ${path_iso}/EFI/miso/${iso_name}.img
        mkdir -p ${work_dir}/efiboot
        mount ${path_iso}/EFI/miso/${iso_name}.img ${work_dir}/efiboot
        local path_efi="${work_dir}/efiboot/EFI"
        mkdir -p ${path_efi}/miso
        copy_boot_images "${path_iso}/${iso_name}/boot" "${path_efi}/miso"
        mkdir -p ${path_efi}/boot
        copy_efi_loaders "${work_dir}/root-image" "${path_efi}/boot"
        local efi_loader=${work_dir}/efiboot/loader
        mkdir -p ${efi_loader}/entries
        write_loader_conf "${efi_loader}"
        write_efi_shellv1_conf "${efi_loader}/entries"
        write_efi_shellv2_conf "${efi_loader}/entries"
        write_dvd_conf "${efi_loader}/entries" "${path_iso}"
        write_dvd_nonfree_conf "${efi_loader}/entries" "${path_iso}"
        copy_efi_shells "${path_efi}"
        umount ${work_dir}/efiboot
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [%s/iso/EFI]" "${iso_name}"
    fi
}

# Prepare /isolinux
make_isolinux() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [%s/iso/isolinux]" "${iso_name}"
        local path=${work_dir}/iso/isolinux
        mkdir -p ${path}
        copy_overlay "${DATADIR}/isolinux" "${path}"
        write_isolinux_cfg "${path}" "${work_dir}/iso"
        write_isolinux_msg "${path}"
        if [[ -e ${profile_dir}/isolinux-overlay ]]; then
            copy_overlay "${profile_dir}/isolinux-overlay" "${path}"
            update_isolinux_cfg "${profile_dir}/isolinux-overlay" "${path}"
            update_isolinux_msg "${profile_dir}/isolinux-overlay" "${path}"
        fi
        copy_isolinux_bin "${work_dir}/root-image" "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [%s/iso/isolinux]" "${iso_name}"
    fi
}

make_isomounts() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [isomounts]"
        write_isomounts "${work_dir}/iso/${iso_name}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [isomounts]"
    fi
}

check_requirements(){
    [[ -f ${run_dir}/.buildiso ]] || die "%s is not a valid iso profiles directory!" "${run_dir}"
    if ! $(is_valid_arch_iso ${target_arch});then
        die "%s is not a valid arch!" "${target_arch}"
    fi
    if ! $(is_valid_branch ${target_branch});then
        die "%s is not a valid branch!" "${target_branch}"
    fi

    if ! is_valid_init "${initsys}";then
        die "%s is not a valid init system!" "${initsys}"
    fi

    local iso_kernel=${kernel:5:1} host_kernel=$(uname -r)

    if [[ ${iso_kernel} < "4" ]] || [[ ${host_kernel%%*.} < "4" ]];then
        use_overlayfs='false'
    fi

    if ${use_overlayfs};then
        iso_fs="overlayfs"
    else
        iso_fs="aufs"
    fi
    import ${LIBDIR}/util-iso-${iso_fs}.sh
}

sign_iso(){
    su ${OWNER} -c "signfile ${iso_dir}/$1"
}

make_torrent(){
    local fn=${iso_file}.torrent
    msg2 "Creating (%s) ..." "${fn}"
    [[ -f ${iso_dir}/${fn} ]] && rm ${iso_dir}/${fn}
    mktorrent ${mktorrent_args[*]} -o ${iso_dir}/${fn} ${iso_dir}/${iso_file}
}

# $1: file
make_checksum(){
    msg "Creating [%s] sum ..." "${iso_checksum}"
    cd ${iso_dir}
    local cs=$(${iso_checksum}sum $1)
    msg2 "%s sum: %s" "${iso_checksum}" "${cs##*/}"
    echo "${cs}" > ${iso_dir}/$1.${iso_checksum}
    msg "Done [%s] sum" "${iso_checksum}"
}

compress_images(){
    local timer=$(get_timer)
    run_safe "make_iso"
    make_checksum "${iso_file}"
    ${sign} && sign_iso "${iso_file}"
    ${torrent} && make_torrent
    user_own "${iso_dir}" "-R"
    show_elapsed_time "${FUNCNAME}" "${timer}"
}

prepare_images(){
    local timer=$(get_timer)
    load_pkgs "${profile_dir}/Packages-Root"
    run_safe "make_image_root"
    if [[ -f "${packages_custom}" ]] ; then
        load_pkgs "${packages_custom}"
        run_safe "make_image_custom"
    fi
    if [[ -f ${profile_dir}/Packages-Live ]]; then
        load_pkgs "${profile_dir}/Packages-Live"
        run_safe "make_image_live"
    fi
    if [[ -f ${packages_mhwd} ]] ; then
        load_pkgs "${packages_mhwd}"
        run_safe "make_image_mhwd"
    fi
    run_safe "make_image_boot"
    if [[ "${target_arch}" == "x86_64" ]]; then
        run_safe "make_efi"
        run_safe "make_efiboot"
    fi
    run_safe "make_isolinux"
    run_safe "make_isomounts"
    show_elapsed_time "${FUNCNAME}" "${timer}"
}

archive_logs(){
    local name=$(gen_iso_fn) ext=log.tar.xz src=${tmp_dir}/archives.list
    find ${log_dir} -maxdepth 1 -name "$name*.log" -printf "%f\n" > $src
    msg2 "Archiving log files [%s] ..." "$name.$ext"
    tar -cJf ${log_dir}/$name.$ext -C ${log_dir} -T $src
    msg2 "Cleaning log files ..."
    find ${log_dir} -maxdepth 1 -name "$name*.log" -delete
}

make_profile(){
    msg "Start building [%s]" "${profile}"
    ${clean_first} && chroot_clean "${work_dir}"
    if ${iso_only}; then
        [[ ! -d ${work_dir} ]] && die "Create images: buildiso -p %s -x" "${profile}"
        compress_images
        ${verbose} && archive_logs
        exit 1
    fi
    if ${images_only}; then
        prepare_images
        ${verbose} && archive_logs
        warning "Continue compress: buildiso -p %s -zc ..." "${profile}"
        exit 1
    else
        prepare_images
        compress_images
        ${verbose} && archive_logs
    fi
    reset_profile
    msg "Finished building [%s]" "${profile}"
    show_elapsed_time "${FUNCNAME}" "${timer_start}"
}

get_pacman_conf(){
    local user_conf=${profile_dir}/user-repos.conf pac_arch='default' conf
    [[ "${target_arch}" == 'x86_64' ]] && pac_arch='multilib'
    if [[ -f ${user_conf} ]];then
        info "detected: %s" "user-repos.conf"
        check_user_repos_conf "${user_conf}"
        conf=${tmp_dir}/custom-pacman.conf
        cat ${DATADIR}/pacman-$pac_arch.conf ${user_conf} > "$conf"
    else
        conf="${DATADIR}/pacman-$pac_arch.conf"
    fi
    echo "$conf"
}

gen_webseed(){
    local webseed url project=$(get_project "${edition}")
        url=${host}/project/${project}/${dist_release}/${profile}/${iso_file}

        local mirrors=('heanet' 'jaist' 'netcologne' 'iweb' 'kent')

    for m in ${mirrors[@]};do
        webseed=${webseed:-}${webseed:+,}"http://${m}.dl.${url}"
    done
    echo ${webseed}
}

load_profile(){
    conf="${profile_dir}/profile.conf"

    info "Profile: [%s]" "${profile}"

    load_profile_config "$conf"

    pacman_conf=$(get_pacman_conf)

    mirrors_conf=$(get_pac_mirrors_conf "${target_branch}")

    iso_file=$(gen_iso_fn).iso

    mkchroot_args+=(-C ${pacman_conf} -S ${mirrors_conf} -B "${build_mirror}/${target_branch}" -K)
    work_dir=${chroots_iso}/${profile}/${target_arch}

    iso_dir="${cache_dir_iso}/${edition}/${dist_release}/${profile}"

    prepare_dir "${iso_dir}"
    user_own "${iso_dir}"

    mktorrent_args=(-v -p -l ${piece_size} -a ${tracker_url} -w $(gen_webseed))
}

prepare_profile(){
    profile=$1
    edition=$(get_edition ${profile})
    profile_dir=${run_dir}/${edition}/${profile}
    check_profile
    load_profile
}

build(){
    prepare_profile "$1"
    make_profile
}
