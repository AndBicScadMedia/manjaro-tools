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

shopt -s nullglob

mv_pkg(){
    msg2 "Moving $1 to ${pkgdir}"
    local ext='pkg.tar.xz'
    mv *.${ext} ${pkgdir}/
}

ch_owner(){
    chown -R "$(get_user):users" "$1"
}

repo_create(){
    msg "Creating repo ${repodir} ..."
    prepare_dir "${repodir}/${arch}"
    local ext='pkg.tar.xz'
    for pkg in ${pkgdir}/*.${ext}; do
	cp $pkg ${repodir}/${arch}/
    done
    cd ${repodir}/${arch}
    repo-add ${repodir}/${arch}/${repodir##*/}.db.tar.xz *.${ext}
    ch_owner "${repodir}"
    msg "Done repo ${repodir}"
}

set_pkgdir(){
    if [[ -n ${pkgdir} ]];then
	pkgdir=${pkgdir}
    elif [[ -n $PKGDEST ]];then
	pkgdir=$PKGDEST
    else
	pkgdir='/var/cache/manjaro-tools/pkg'
	prepare_dir "${pkgdir}"
    fi
}

sign_pkgs(){
    ch_owner "${pkgdir}"
    cd $pkgdir
    su $(get_user) <<'EOF'
signpkgs
EOF
}

get_profiles(){
    local prof= temp=
    for item in $(ls ${profiledir}/*.set);do
	temp=${item##*/}
	prof=${prof:-}${prof:+|}${temp%.set}
    done
    echo $prof
}

get_user(){
    echo $(ls ${chrootdir} | cut -d' ' -f1 | grep -v root | grep -v lock)
}

prepare_dir(){
    if ! [[ -d $1 ]];then
	mkdir -p $1
    fi
    ch_owner "$1"
}

chroot_clean(){
    for copy in "${chrootdir}"/*; do
	[[ -d "${copy}" ]] || continue
	msg2 "Deleting chroot copy '$(basename "${copy}")'..."

	exec 9>"${copy}.lock"
	if ! flock -n 9; then
	    stat_busy "Locking chroot copy '${copy}'"
	    flock 9
	    stat_done
	fi

	if [[ "$(stat -f -c %T "${copy}")" == btrfs ]]; then
	    { type -P btrfs && btrfs subvolume delete "${copy}"; } &>/dev/null
	fi
	rm -rf --one-file-system "${copy}"
    done
    exec 9>&-

    rm -rf --one-file-system "${chrootdir}"
}

clean_dir(){
    msg2 "Cleaning $1 ..."
    rm $1/*
}

git_clean(){
    msg "Cleaning ${rundir} ..."
    git clean -dfx$1
}

chroot_create(){
    mkdir -p "${chrootdir}"
    setarch ${arch} \
	mkchroot ${mkchroot_args[*]} ${chrootdir}/root ${base_packages[*]} || abort
}

chroot_update(){
    setarch ${arch} \
	mkchroot ${mkchroot_args[*]} -u ${chrootdir}/$(get_user) || abort
}

chroot_init(){
      if [[ ! -d "${chrootdir}" ]]; then
	  msg "Creating chroot for [${branch}] (${arch})..."
	  chroot_create
      elif ${clean_first};then
	  msg "Creating chroot for [${branch}] (${arch})..."
	  chroot_clean
	  clean_dir ${pkgdir}
# 	  if ${repo};then
# 	      clean_dir ${repodir}
# 	  fi
	  chroot_create
      else
	  msg "Updating chroot for [${branch}] (${arch})..."
	  chroot_update
      fi
}

eval_profile(){
    eval "case ${profile} in
	    $(get_profiles)) is_profile=true ;;
	    *) is_profile=false ;;
	esac"
}

chroot_build(){
    if ${is_profile};then
	msg "Start building profile: [${profile}]"
	for pkg in $(cat ${profiledir}/${profile}.set); do
	    cd $pkg
	    setarch ${arch} \
		mkchrootpkg ${mkchrootpkg_args[*]} -- "${makepkg_args[*]}" || break
	    if [[ $pkg == 'eudev' ]]; then
		local blacklist=('libsystemd') temp=
		pacman -Rdd "${blacklist[@]}" -r ${chrootdir}/$(get_user) --noconfirm
		if [[ -z $PKGDEST ]];then
		    temp=$pkg
		else
		    temp=$pkgdir/$pkg
		fi
		pacman -U $temp*${arch}*pkg*z -r ${chrootdir}/$(get_user) --noconfirm
	    fi
	    mv_pkg "${pkg}"
	    cd ..
	done
	msg "Finished building profile: [${profile}]"
    else
	cd ${profile}
	setarch ${arch} \
	    mkchrootpkg ${mkchrootpkg_args[*]} -- "${makepkg_args[*]}" || abort
	mv_pkg "${profile}"
	cd ..
    fi
}

display_settings(){
    msg "manjaro-tools version: ${version}"

    msg "OPTARGS:"
    msg2 "arch: ${arch}"
    msg2 "branch: ${branch}"
    msg2 "chroots: ${chroots}"

    msg "PATHS:"
    msg2 "chrootdir: ${chrootdir}"
    msg2 "profiledir: ${profiledir}"
    msg2 "pkgdir: ${pkgdir}"
    msg2 "PKGDEST: ${PKGDEST}"
    msg2 "repodir: ${repodir}"
    msg2 "pacman_conf: ${pacman_conf}"
    msg2 "makepkg_conf: ${makepkg_conf}"

    if ${clean_first};then
	msg "PKG:"
	msg2 "base_packages: ${base_packages[*]}"
    fi

    msg "SETS:"
    msg2 "profiles: $(get_profiles)"
    msg2 "profile: ${profile}"
    msg2 "is_profile: ${is_profile}"

    if ${is_profile};then
	msg "These packages will be built:"
	local list=$(cat ${profiledir}/${profile}.set)
	for item in ${list[@]}; do
	    msg2 "$item"
	done
    else
	msg "This package will be built:"
	msg2 "${profile}"
    fi
}

create_set(){
    msg "Creating [${profiledir}/${name}.set] ..."
    if [[ -f ${profiledir}/${name}.set ]];then
	msg2 "Backing up ${profiledir}/${name}.set.orig"
	mv "${profiledir}/${name}.set" "${profiledir}/${name}.set.orig"
    fi
    local list=$(find * -maxdepth 0 -type d | sort)
    for item in ${list[@]};do
	cd $item
	if [[ -f PKGBUILD ]];then
	    msg2 "Adding ${item##*/}"
	    echo ${item##*/} >> ${profiledir}/${name}.set || break
	fi
	cd ..
    done
}

remove_set(){
    msg "Removing [${profiledir}/${name}.set] ..."
    rm ${profiledir}/${name}.set
}

display_set(){
    local list=$(cat ${profiledir}/${name}.set)
    msg "Content of [${profiledir}/${name}.set] ..."
    for item in ${list[@]}; do
	msg2 $item
    done
}