#!/bin/bash
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

declare -A pseudofs_types=([anon_inodefs]=1
                           [autofs]=1
                           [bdev]=1
                           [binfmt_misc]=1
                           [cgroup]=1
                           [configfs]=1
                           [cpuset]=1
                           [debugfs]=1
                           [devfs]=1
                           [devpts]=1
                           [devtmpfs]=1
                           [dlmfs]=1
                           [fuse.gvfs-fuse-daemon]=1
                           [fusectl]=1
                           [hugetlbfs]=1
                           [mqueue]=1
                           [nfsd]=1
                           [none]=1
                           [pipefs]=1
                           [proc]=1
                           [pstore]=1
                           [ramfs]=1
                           [rootfs]=1
                           [rpc_pipefs]=1
                           [securityfs]=1
                           [sockfs]=1
                           [spufs]=1
                           [sysfs]=1
                           [tmpfs]=1)

declare -A fsck_types=([cramfs]=1
                       [exfat]=1
                       [ext2]=1
                       [ext3]=1
                       [ext4]=1
                       [ext4dev]=1
                       [jfs]=1
                       [minix]=1
                       [msdos]=1
                       [reiserfs]=1
                       [vfat]=1
                       [xfs]=1)

ignore_error() {
	"$@" 2>/dev/null
	return 0
}

track_mount() {
# 	if [[ -z $CHROOT_ACTIVE_MOUNTS ]]; then
# 	  CHROOT_ACTIVE_MOUNTS=()
# 	  trap 'chroot_umount' EXIT
# 	fi

	mount "$@" && CHROOT_ACTIVE_MOUNTS=("$2" "${CHROOT_ACTIVE_MOUNTS[@]}")
}

mount_conditionally() {
      local cond=$1; shift
      if eval "$cond"; then
	  track_mount "$@"
      fi
}

api_fs_mount() {
	CHROOT_ACTIVE_MOUNTS=()
	[[ $(trap -p EXIT) ]] && die '(BUG): attempting to overwrite existing EXIT trap'
	trap 'chroot_umount' EXIT
	mount_conditionally "! mountpoint -q '$1'" "$1" "$1" --bind &&
	track_mount proc "$1/proc" -t proc -o nosuid,noexec,nodev &&
	track_mount sys "$1/sys" -t sysfs -o nosuid,noexec,nodev,ro &&
# 	ignore_error mount_conditionally "[[ -d '$1/sys/firmware/efi/efivars' ]]" \
# 	   efivarfs "$1/sys/firmware/efi/efivars" -t efivarfs -o nosuid,noexec,nodev &&
	track_mount udev "$1/dev" -t devtmpfs -o mode=0755,nosuid &&
	track_mount devpts "$1/dev/pts" -t devpts -o mode=0620,gid=5,nosuid,noexec &&
	track_mount shm "$1/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev &&
	track_mount run "$1/run" -t tmpfs -o nosuid,nodev,mode=0755 &&
	track_mount tmp "$1/tmp" -t tmpfs -o mode=1777,strictatime,nodev,nosuid
}

chroot_umount() {
	umount "${CHROOT_ACTIVE_MOUNTS[@]}"
	unset CHROOT_ACTIVE_MOUNTS
}

fstype_is_pseudofs() {
	(( pseudofs_types["$1"] ))
}

fstype_has_fsck() {
	(( fsck_types["$1"] ))
}

valid_number_of_base() {
	local base=$1 len=${#2} i=

	for (( i = 0; i < len; i++ )); do
	  { _=$(( $base#${2:i:1} )) || return 1; } 2>/dev/null
	done

	return 0
}

mangle() {
	local i= chr= out=

	unset {a..f} {A..F}

	for (( i = 0; i < ${#1}; i++ )); do
	  chr=${1:i:1}
	  case $chr in
	    [[:space:]\\])
	      printf -v chr '%03o' "'$chr"
	      out+=\\
	      ;;
	  esac
	  out+=$chr
	done

	printf '%s' "$out"
}

unmangle() {
	local i= chr= out= len=$(( ${#1} - 4 ))

	unset {a..f} {A..F}

	for (( i = 0; i < len; i++ )); do
	  chr=${1:i:1}
	  case $chr in
	    \\)
	      if valid_number_of_base 8 "${1:i+1:3}" ||
		  valid_number_of_base 16 "${1:i+1:3}"; then
		printf -v chr '%b' "${1:i:4}"
		(( i += 3 ))
	      fi
	      ;;
	  esac
	  out+=$chr
	done

	printf '%s' "$out${1:i}"
}

dm_name_for_devnode() {
	read dm_name <"/sys/class/block/${1#/dev/}/dm/name"
	if [[ $dm_name ]]; then
	  printf '/dev/mapper/%s' "$dm_name"
	else
	  # don't leave the caller hanging, just print the original name
	  # along with the failure.
	  print '%s' "$1"
	  error 'Failed to resolve device mapper name for: %s' "$1"
	fi
}
