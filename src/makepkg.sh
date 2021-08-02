#!/usr/bin/env bash
#
#   makepkg - make packages compatible for use with pacman
#
#   Copyright (c) 2006-2021 Pacman Development Team <pacman-dev@archlinux.org>
#   Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
#   Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
#   Copyright (c) 2006 by Miklos Vajna <vmiklos@frugalware.org>
#   Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
#   Copyright (c) 2006 by Alex Smith <alex@alex-smith.me.uk>
#   Copyright (c) 2006 by Andras Voroskoi <voroskoi@frugalware.org>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# makepkg uses quite a few external programs during its execution. You
# need to have at least the following installed for makepkg to function:
#   awk, bsdtar (libarchive), bzip2, coreutils, fakeroot, file, find (findutils),
#   gettext, gpg, grep, gzip, sed, tput (ncurses), xz

# gettext initialization
export TEXTDOMAIN='pacman-scripts'
export TEXTDOMAINDIR='/usr/share/locale'

# file -i does not work on Mac OSX unless legacy mode is set
export COMMAND_MODE='legacy'
# Ensure CDPATH doesn't screw with our cd calls
unset CDPATH
# Ensure GREP_OPTIONS doesn't screw with our grep calls
unset GREP_OPTIONS

declare -r makepkg_program_name="${makepkg_program_name:-makedeb-makepkg}"
declare -r makepkg_version='6.0.0'
declare -r confdir='/etc'
declare -r BUILDSCRIPT='PKGBUILD'
declare -r startdir="$(pwd -P)"

declare -r makepkg_target_os="arch"
declare -r distro_release_name="$(lsb_release -cs)"

LIBRARY=${LIBRARY:-'./functions'}    # REMOVE AT PACKAGING
LIBRARY=${LIBRARY:-'/usr/share/makedeb-makepkg'}

# Options
ASDEPS=0
BUILDFUNC=0
BUILDPKG=1
CHECKFUNC=0
CLEANBUILD=0
CLEANUP=0
DEP_BIN=0
DISTROVARIABLES='n'
FORCE=0
GENINTEG=0
HOLDVER=0
IGNOREARCH=0
INFAKEROOT=0
INSTALL=0
LOGGING=0
NEEDED=0
NOARCHIVE=0
NOBUILD=0
NODEPS=0
NOEXTRACT=0
PKGFUNC=0
PKGVERFUNC=0
PREPAREFUNC=0
REPKG=0
REPRODUCIBLE=0
RMDEPS=0
SKIPCHECKSUMS=0
SKIPPGPCHECK=0
SIGNPKG=''
SPLITPKG=0
SOURCEONLY=0
VERIFYSOURCE=0

if [[ -n $SOURCE_DATE_EPOCH ]]; then
	REPRODUCIBLE=1
else
	SOURCE_DATE_EPOCH=$(date +%s)
fi
export SOURCE_DATE_EPOCH

PACMAN_OPTS=()

shopt -s extglob

### SUBROUTINES ###

# Import libmakepkg
for lib in "$LIBRARY"/*.sh; do
	source "$lib"
done

##
# Special exit call for traps, Don't print any error messages when inside,
# the fakeroot call, the error message will be printed by the main call.
##
trap_exit() {
	local signal=$1; shift

	if (( ! INFAKEROOT )); then
		echo
		error "$@"
	fi
	[[ -n $srclinks ]] && rm -rf "$srclinks"

	# unset the trap for this signal, and then call the default handler
	trap -- "$signal"
	kill "-$signal" "$$"
}


##
# Clean up function. Called automatically when the script exits.
##
clean_up() {
	local EXIT_CODE=$?

	if (( INFAKEROOT )); then
		# Don't clean up when leaving fakeroot, we're not done yet.
		return 0
	fi

	if [[ -p $logpipe ]]; then
		rm "$logpipe"
	fi

	if (( (EXIT_CODE == E_OK || EXIT_CODE == E_INSTALL_FAILED) && BUILDPKG && CLEANUP )); then
		local pkg file

		# If it's a clean exit and -c/--clean has been passed...
		msg "$(gettext "Cleaning up...")"
		rm -rf "$pkgdirbase" "$srcdir"
		if [[ -n $pkgbase ]]; then
			local fullver=$(get_full_version)
			# Can't do this unless the BUILDSCRIPT has been sourced.
			if (( PKGVERFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-pkgver.log"*
			fi
			if (( PREPAREFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-prepare.log"*
			fi
			if (( BUILDFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-build.log"*
			fi
			if (( CHECKFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-check.log"*
			fi
			if (( PKGFUNC )); then
				rm -f "${pkgbase}-${fullver}-${CARCH}-package.log"*
			elif (( SPLITPKG )); then
				for pkg in ${pkgname[@]}; do
					rm -f "${pkgbase}-${fullver}-${CARCH}-package_${pkg}.log"*
				done
			fi

			# clean up dangling symlinks to packages
			for pkg in ${pkgname[@]}; do
				for file in ${pkg}-*-*-*{${PKGEXT},${SRCEXT}}; do
					if [[ -h $file && ! -e $file ]]; then
						rm -f "$file"
					fi
				done
			done
		fi
	fi

	if ! remove_deps && (( EXIT_CODE == E_OK )); then
	    exit $E_REMOVE_DEPS_FAILED
	else
	    exit $EXIT_CODE
	fi
}

enter_fakeroot() {
	msg "$(gettext "Entering %s environment...")" "fakeroot"
	fakeroot -- bash -$- "${BASH_SOURCE[0]}" -F "${ARGLIST[@]}" || exit $?
}

# Automatically update pkgver variable if a pkgver() function is provided
# Re-sources the PKGBUILD afterwards to allow for other variables that use $pkgver
update_pkgver() {
	msg "$(gettext "Starting %s()...")" "pkgver"
	newpkgver=$(run_function_safe pkgver)
	if (( $? != 0 )); then
		error_function pkgver
	fi
	if ! check_pkgver "$newpkgver"; then
		error "$(gettext "pkgver() generated an invalid version: %s")" "$newpkgver"
		exit $E_PKGBUILD_ERROR
	fi

	if [[ -n $newpkgver && $newpkgver != "$pkgver" ]]; then
		if [[ -w $BUILDFILE ]]; then
			mapfile -t buildfile < "$BUILDFILE"
			buildfile=("${buildfile[@]/#pkgver=*([^ ])/pkgver=$newpkgver}")
			buildfile=("${buildfile[@]/#pkgrel=*([^ ])/pkgrel=1}")
			if ! printf '%s\n' "${buildfile[@]}" > "$BUILDFILE"; then
				error "$(gettext "Failed to update %s from %s to %s")" \
						"pkgver" "$pkgver" "$newpkgver"
				exit $E_PKGBUILD_ERROR
			fi
			source_safe "$BUILDFILE"
			local fullver=$(get_full_version)
			msg "$(gettext "Updated version: %s")" "$pkgbase $fullver"
		else
			warning "$(gettext "%s is not writeable -- pkgver will not be updated")" \
					"$BUILDFILE"
		fi
	fi
}

# Print 'source not found' error message and exit makepkg
missing_source_file() {
	error "$(gettext "Unable to find source file %s.")" "$(get_filename "$1")"
	plainerr "$(gettext "Aborting...")"
	exit $E_MISSING_FILE
}

run_pacman() {
	local cmd cmdescape
	if [[ $1 = -@(T|Q)*([[:alpha:]]) ]]; then
		cmd=("$PACMAN_PATH" "$@")
	else
		cmd=("$PACMAN_PATH" "${PACMAN_OPTS[@]}" "$@")
		cmdescape="$(printf '%q ' "${cmd[@]}")"
		if (( ${#PACMAN_AUTH[@]} )); then
			if in_array '%c' "${PACMAN_AUTH[@]}"; then
				cmd=("${PACMAN_AUTH[@]/\%c/$cmdescape}")
			else
				cmd=("${PACMAN_AUTH[@]}" "${cmd[@]}")
			fi
		elif type -p sudo >/dev/null; then
			cmd=(sudo "${cmd[@]}")
		else
			cmd=(su root -c "$cmdescape")
		fi
		local lockfile="$(pacman-conf DBPath)/db.lck"
		while [[ -f $lockfile ]]; do
			local timer=0
			msg "$(gettext "Pacman is currently in use, please wait...")"
			while [[ -f $lockfile ]] && (( timer < 10 )); do
				(( ++timer ))
				sleep 3
			done
		done
	fi
	"${cmd[@]}"
}

check_deps() {
	(( $# > 0 )) || return 0

	local ret=0
	local pmout
	pmout=$(run_pacman -T "$@")
	ret=$?

	if (( ret == 127 )); then #unresolved deps
		printf "%s\n" "$pmout"
	elif (( ret )); then
		error "$(gettext "'%s' returned a fatal error (%i): %s")" "$PACMAN" "$ret" "$pmout"
		return "$ret"
	fi
}

handle_deps() {
	local R_DEPS_SATISFIED=0
	local R_DEPS_MISSING=1

	(( $# == 0 )) && return $R_DEPS_SATISFIED

	local deplist=("$@")

	if (( ! DEP_BIN )); then
		return $R_DEPS_MISSING
	fi

	if (( DEP_BIN )); then
		# install missing deps from binary packages (using pacman -S)
		msg "$(gettext "Installing missing dependencies...")"

		if ! run_pacman -S --asdeps "${deplist[@]}"; then
			error "$(gettext "'%s' failed to install missing dependencies.")" "$PACMAN"
			return $R_DEPS_MISSING
		fi
	fi

	# we might need the new system environment
	# save our shell options and turn off extglob
	local shellopts=$(shopt -p extglob)
	shopt -u extglob
	source /etc/profile &>/dev/null
	eval "$shellopts"

	# umask might have been changed in /etc/profile
	# ensure that sane default is set again
	umask 0022

	return $R_DEPS_SATISFIED
}

resolve_deps() {
	local R_DEPS_SATISFIED=0
	local R_DEPS_MISSING=1

	# deplist cannot be declared like this: local deplist=$(foo)
	# Otherwise, the return value will depend on the assignment.
	local deplist
	deplist=($(check_deps "$@")) || exit $E_INSTALL_DEPS_FAILED
	[[ -z $deplist ]] && return $R_DEPS_SATISFIED

	if handle_deps "${deplist[@]}"; then
		# check deps again to make sure they were resolved
		deplist=$(check_deps "$@")
		[[ -z $deplist ]] && return $R_DEPS_SATISFIED
	fi

	msg "$(gettext "Missing dependencies:")"
	local dep
	for dep in ${deplist[@]}; do
		msg2 "$dep"
	done

	return $R_DEPS_MISSING
}

remove_deps() {
	(( ! RMDEPS )) && return 0

	# check for packages removed during dependency install (e.g. due to conflicts)
	# removing all installed packages is risky in this case
	if [[ -n $(grep -xvFf <(printf '%s\n' "${current_pkglist[@]}") \
			<(printf '%s\n' "${original_pkglist[@]}")) ]]; then
		warning "$(gettext "Failed to remove installed dependencies.")"
		return $E_REMOVE_DEPS_FAILED
	fi

	local deplist
	deplist=($(grep -xvFf <(printf "%s\n" "${original_pkglist[@]}") \
			<(printf "%s\n" "${current_pkglist[@]}")))
	if [[ -z $deplist ]]; then
		return 0
	fi

	msg "Removing installed dependencies..."
	# exit cleanly on failure to remove deps as package has been built successfully
	if ! run_pacman -Rnu ${deplist[@]}; then
		warning "$(gettext "Failed to remove installed dependencies.")"
		return $E_REMOVE_DEPS_FAILED
	fi
}

error_function() {
	# first exit all subshells, then print the error
	if (( ! BASH_SUBSHELL )); then
		error "$(gettext "A failure occurred in %s().")" "$1"
		plainerr "$(gettext "Aborting...")"
	fi
	exit $E_USER_FUNCTION_FAILED
}

merge_arch_attrs() {
	local attr current_env_vars supported_attrs=(
		provides conflicts depends replaces optdepends
		makedepends checkdepends)

	for attr in "${supported_attrs[@]}"; do
		[[ "${DISTROVARIABLES}" == "y" ]] && local distro_attr_data="$(eval echo "\${${distro_release_name}_${attr}_$CARCH[@]}")"

		if [[ "${distro_attr_data}" != "" ]]; then
			local attr_data="${distro_attr_data}"
		else
			local attr_data="$(eval echo "\${${attr}_$CARCH[@]}")"
		fi

		eval "$attr+=(${attr_data})"
	done

	# ensure that calling this function is idempotent.
	unset -v "${supported_attrs[@]/%/_$CARCH}"
}

source_buildfile() {
	source_safe "$@"
}

run_function_safe() {
	local restoretrap restoreshopt

	# we don't set any special shopts of our own, but we don't want the user to
	# muck with our environment.
	restoreshopt=$(shopt -p)

	# localize 'set' shell options to this function - this does not work for shopt
	local -
	shopt -o -s errexit errtrace

	restoretrap=$(trap -p ERR)
	trap "error_function '$1'" ERR

	run_function "$1"

	trap - ERR
	eval "$restoretrap"
	eval "$restoreshopt"
}

run_function() {
	if [[ -z $1 ]]; then
		return 1
	fi
	local pkgfunc="$1"

	if (( ! BASH_SUBSHELL )); then
		msg "$(gettext "Starting %s()...")" "$pkgfunc"
	fi
	cd_safe "$srcdir"

	local ret=0
	if (( LOGGING )); then
		local fullver=$(get_full_version)
		local BUILDLOG="$LOGDEST/${pkgbase}-${fullver}-${CARCH}-$pkgfunc.log"
		if [[ -f $BUILDLOG ]]; then
			local i=1
			while true; do
				if [[ -f $BUILDLOG.$i ]]; then
					i=$(($i +1))
				else
					break
				fi
			done
			mv "$BUILDLOG" "$BUILDLOG.$i"
		fi

		# ensure overridden package variables survive tee with split packages
		logpipe=$(mktemp -u "$LOGDEST/logpipe.XXXXXXXX")
		mkfifo "$logpipe"
		tee "$BUILDLOG" < "$logpipe" &
		local teepid=$!

		$pkgfunc &>"$logpipe"

		wait -f $teepid
		rm "$logpipe"
	else
		"$pkgfunc"
	fi
}

run_prepare() {
	run_function_safe "prepare"
}

run_build() {
	run_function_safe "build"
}

run_check() {
	run_function_safe "check"
}

run_package() {
	run_function_safe "package${1:+_$1}"
}

find_libdepends() {
	local d sodepends

	sodepends=0
	for d in "${depends[@]}"; do
		if [[ $d = *.so ]]; then
			sodepends=1
			break
		fi
	done

	if (( sodepends == 0 )); then
		(( ${#depends[@]} )) && printf '%s\n' "${depends[@]}"
		return 0
	fi

	local libdeps filename soarch sofile soname soversion
	declare -A libdeps

	while IFS= read -rd '' filename; do
		# get architecture of the file; if soarch is empty it's not an ELF binary
		soarch=$(LC_ALL=C readelf -h "$filename" 2>/dev/null | sed -n 's/.*Class.*ELF\(32\|64\)/\1/p')
		[[ -n "$soarch" ]] || continue

		# process all libraries needed by the binary
		for sofile in $(LC_ALL=C readelf -d "$filename" 2>/dev/null | sed -nr 's/.*Shared library: \[(.*)\].*/\1/p')
		do
			# extract the library name: libfoo.so
			soname="${sofile%.so?(+(.+([0-9])))}".so
			# extract the major version: 1
			soversion="${sofile##*\.so\.}"

			if [[ ${libdeps[$soname]} ]]; then
				if [[ ${libdeps[$soname]} != *${soversion}-${soarch}* ]]; then
					libdeps[$soname]+=" ${soversion}-${soarch}"
				fi
			else
				libdeps[$soname]="${soversion}-${soarch}"
			fi
		done
	done < <(find "$pkgdir" -type f -perm -u+x -print0)

	local libdepends v
	for d in "${depends[@]}"; do
		case "$d" in
			*.so)
				if [[ ${libdeps[$d]} ]]; then
					for v in ${libdeps[$d]}; do
						libdepends+=("$d=$v")
					done
				else
					warning "$(gettext "Library listed in %s is not required by any files: %s")" "'depends'" "$d"
					libdepends+=("$d")
				fi
				;;
			*)
				libdepends+=("$d")
				;;
		esac
	done

	(( ${#libdepends[@]} )) && printf '%s\n' "${libdepends[@]}"
}


find_libprovides() {
	local p versioned_provides libprovides missing
	for p in "${provides[@]}"; do
		missing=0
		versioned_provides=()
		case "$p" in
			*.so)
				mapfile -t filename < <(find "$pkgdir" -type f -name $p\* | LC_ALL=C sort)
				if [[ $filename ]]; then
					# packages may provide multiple versions of the same library
					for fn in "${filename[@]}"; do
						# check if we really have a shared object
						if LC_ALL=C readelf -h "$fn" 2>/dev/null | grep -q '.*Type:.*DYN (Shared object file).*'; then
							# get the string binaries link to (e.g. libfoo.so.1.2 -> libfoo.so.1)
							local sofile=$(LC_ALL=C readelf -d "$fn" 2>/dev/null | sed -n 's/.*Library soname: \[\(.*\)\].*/\1/p')
							if [[ -z "$sofile" ]]; then
								warning "$(gettext "Library listed in %s is not versioned: %s")" "'provides'" "$p"
								continue
							fi

							# get the library architecture (32 or 64 bit)
							local soarch=$(LC_ALL=C readelf -h "$fn" | sed -n 's/.*Class.*ELF\(32\|64\)/\1/p')

							# extract the library major version
							local soversion="${sofile##*\.so\.}"

							versioned_provides+=("${p}=${soversion}-${soarch}")
						else
							warning "$(gettext "Library listed in %s is not a shared object: %s")" "'provides'" "$p"
						fi
					done
				else
					missing=1
				fi
				;;
		esac

		if (( missing )); then
			warning "$(gettext "Cannot find library listed in %s: %s")" "'provides'" "$p"
		fi
		if (( ${#versioned_provides[@]} > 0 )); then
			libprovides+=("${versioned_provides[@]}")
		else
			libprovides+=("$p")
		fi
	done

	(( ${#libprovides[@]} )) && printf '%s\n' "${libprovides[@]}"
}

write_kv_pair() {
	local key="$1"
	shift

	for val in "$@"; do
		if [[ $val = *$'\n'* ]]; then
			error "$(gettext "Invalid value for %s: %s")" "$key" "$val"
			exit $E_PKGBUILD_ERROR
		fi
		printf "%s = %s\n" "$key" "$val"
	done
}

write_pkginfo() {
	local size=$(dirsize)

	merge_arch_attrs

	if [[ "${DISTROVARIABLES}" == "y" ]]; then
		check_distro_variables
	fi

	printf "# Generated by makedeb-makepkg %s\n" "$makepkg_version"
	printf "# using %s\n" "$(fakeroot -v)"

	write_kv_pair "generated-by" "makedeb-makepkg"
	write_kv_pair "pkgname" "$pkgname"
	write_kv_pair "pkgbase" "$pkgbase"

	local fullver=$(get_full_version)
	write_kv_pair "pkgver" "$fullver"

	# TODO: all fields should have this treatment
	local spd="${pkgdesc//+([[:space:]])/ }"
	spd=("${spd[@]#[[:space:]]}")
	spd=("${spd[@]%[[:space:]]}")

	write_kv_pair "pkgdesc" "$spd"
	write_kv_pair "url" "$url"
	write_kv_pair "builddate" "$SOURCE_DATE_EPOCH"
	write_kv_pair "packager" "$PACKAGER"
	write_kv_pair "size" "$size"
	write_kv_pair "arch" "$pkgarch"

	mapfile -t provides < <(find_libprovides)
	mapfile -t depends < <(find_libdepends)

	write_kv_pair "license"     "${license[@]}"
	write_kv_pair "replaces"    "${replaces[@]}"
	write_kv_pair "group"       "${groups[@]}"
	write_kv_pair "conflict"    "${conflicts[@]}"
	write_kv_pair "provides"    "${provides[@]}"
	write_kv_pair "backup"      "${backup[@]}"
	write_kv_pair "depend"      "${depends[@]}"
	write_kv_pair "optdepend"   "${optdepends[@]//+([[:space:]])/ }"
	write_kv_pair "makedepend"  "${makedepends[@]}"
	write_kv_pair "checkdepend" "${checkdepends[@]}"
}

write_buildinfo() {
	write_kv_pair "format" "2"

	write_kv_pair "pkgname" "$pkgname"
	write_kv_pair "pkgbase" "$pkgbase"

	local fullver=$(get_full_version)
	write_kv_pair "pkgver" "$fullver"

	write_kv_pair "pkgarch" "$pkgarch"

	local sum="$(sha256sum "${BUILDFILE}")"
	sum=${sum%% *}
	write_kv_pair "pkgbuild_sha256sum" $sum

	write_kv_pair "packager" "${PACKAGER}"
	write_kv_pair "builddate" "${SOURCE_DATE_EPOCH}"
	write_kv_pair "builddir"  "${BUILDDIR}"
	write_kv_pair "startdir"  "${startdir}"
	write_kv_pair "buildtool" "${BUILDTOOL:-makepkg}"
	write_kv_pair "buildtoolver" "${BUILDTOOLVER:-$makepkg_version}"
	write_kv_pair "buildenv" "${BUILDENV[@]}"
	write_kv_pair "options" "${OPTIONS[@]}"

	local pkginfos_parsed=($(LC_ALL=C run_pacman -Qi | awk -F': ' '\
		/^Name .*/ {printf "%s", $2} \
		/^Version .*/ {printf "-%s", $2} \
		/^Architecture .*/ {print "-"$2} \
		'))

	write_kv_pair "installed" "${pkginfos_parsed[@]}"
}

# build a sorted NUL-separated list of the full contents of the current
# directory suitable for passing to `bsdtar --files-from`
# database files are placed at the beginning of the package regardless of
# sorting
list_package_files() {
	(
		export LC_COLLATE=C
		shopt -s dotglob globstar
		# bash 5.0 only works with combo directory + file globs
		printf '%s\0' **/*
	)
}

create_package() {
	if [[ ! -d $pkgdir ]]; then
		error "$(gettext "Missing %s directory.")" "\$pkgdir/"
		plainerr "$(gettext "Aborting...")"
		exit $E_MISSING_PKGDIR
	fi

	cd_safe "$pkgdir"
	(( NOARCHIVE )) || msg "$(gettext "Creating package \"%s\"...")" "$pkgname"

	pkgarch=$(get_pkg_arch)
	msg2 "$(gettext "Generating %s file...")" ".PKGINFO"
	write_pkginfo > .PKGINFO
	msg2 "$(gettext "Generating %s file...")" ".BUILDINFO"
	write_buildinfo > .BUILDINFO

	# check for changelog/install files
	for i in 'changelog/.CHANGELOG' 'install/.INSTALL'; do
		IFS='/' read -r orig dest < <(printf '%s\n' "$i")

		if [[ -n ${!orig} ]]; then
			msg2 "$(gettext "Adding %s file...")" "$orig"
			if ! cp "$startdir/${!orig}" "$dest"; then
				error "$(gettext "Failed to add %s file to package.")" "$orig"
				exit $E_MISSING_FILE
			fi
			chmod 644 "$dest"
		fi
	done

	(( NOARCHIVE )) && return 0

	# tar it up
	local fullver=$(get_full_version)
	local pkg_file="$PKGDEST/${pkgname}-${fullver}-${pkgarch}${PKGEXT}"
	local ret=0

	[[ -f $pkg_file ]] && rm -f "$pkg_file"
	[[ -f $pkg_file.sig ]] && rm -f "$pkg_file.sig"

	# ensure all elements of the package have the same mtime
	find . -exec touch -h -d @$SOURCE_DATE_EPOCH {} +

	msg2 "$(gettext "Generating .MTREE file...")"
	list_package_files | LANG=C bsdtar -cnf - --format=mtree \
		--options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
		--null --files-from - --exclude .MTREE | gzip -c -f -n > .MTREE
	touch -d @$SOURCE_DATE_EPOCH .MTREE

	msg2 "$(gettext "Compressing package...")"
	# TODO: Maybe this can be set globally for robustness
	shopt -s -o pipefail
	list_package_files | LANG=C bsdtar --no-fflags -cnf - --null --files-from - |
		compress_as "$PKGEXT" > "${pkg_file}" || ret=$?

	shopt -u -o pipefail

	if (( ret )); then
		error "$(gettext "Failed to create package file.")"
		exit $E_PACKAGE_FAILED
	fi
}

create_debug_package() {
	# check if a debug package was requested
	if ! check_option "debug" "y" || ! check_option "strip" "y"; then
		return 0
	fi

	local pkgdir="$pkgdirbase/$pkgbase-debug"

	# check if we have any debug symbols to package
	if dir_is_empty "$pkgdir/usr/lib/debug"; then
		return 0
	fi

	unset groups depends optdepends provides conflicts replaces backup install changelog

	local pkg
	for pkg in ${pkgname[@]}; do
		if [[ $pkg != $pkgbase ]]; then
			provides+=("$pkg-debug")
		fi
	done

	pkgdesc="Detached debugging symbols for $pkgname"
	pkgname=$pkgbase-debug

	create_package
}

create_srcpackage() {
	local ret=0
	msg "$(gettext "Creating source package...")"
	local srclinks="$(mktemp -d "$startdir"/srclinks.XXXXXXXXX)"
	mkdir "${srclinks}"/${pkgbase}

	msg2 "$(gettext "Adding %s...")" "$BUILDSCRIPT"
	ln -s "${BUILDFILE}" "${srclinks}/${pkgbase}/${BUILDSCRIPT}"

	msg2 "$(gettext "Generating %s file...")" .SRCINFO
	write_srcinfo > "$srclinks/$pkgbase"/.SRCINFO

	local file all_sources

	get_all_sources 'all_sources'
	for file in "${all_sources[@]}"; do
		if [[ "$file" = "$(get_filename "$file")" ]] || (( SOURCEONLY == 2 )); then
			local absfile
			absfile=$(get_filepath "$file") || missing_source_file "$file"
			msg2 "$(gettext "Adding %s...")" "${absfile##*/}"
			ln -s "$absfile" "$srclinks/$pkgbase"
		fi
	done

	# set pkgname the same way we do for running package(), this way we get
	# the right value in extract_function_variable
	local pkgname_backup=(${pkgname[@]})
	local i pkgname
	for i in 'changelog' 'install'; do
		local file files

		[[ ${!i} ]] && files+=("${!i}")
		for pkgname in "${pkgname_backup[@]}"; do
			if extract_function_variable "package_$pkgname" "$i" 0 file; then
				files+=("$file")
			fi
		done

		for file in "${files[@]}"; do
			if [[ $file && ! -f "${srclinks}/${pkgbase}/$file" ]]; then
				msg2 "$(gettext "Adding %s file (%s)...")" "$i" "${file}"
				ln -s "${startdir}/$file" "${srclinks}/${pkgbase}/"
			fi
		done
	done
	pkgname=(${pkgname_backup[@]})

	local fullver=$(get_full_version)
	local pkg_file="$SRCPKGDEST/${pkgbase}-${fullver}${SRCEXT}"

	# tar it up
	msg2 "$(gettext "Compressing source package...")"
	cd_safe "${srclinks}"

	# TODO: Maybe this can be set globally for robustness
	shopt -s -o pipefail
	LANG=C bsdtar --no-fflags -cLf - ${pkgbase} | compress_as "$SRCEXT" > "${pkg_file}" || ret=$?

	shopt -u -o pipefail

	if (( ret )); then
		error "$(gettext "Failed to create source package file.")"
		exit $E_PACKAGE_FAILED
	fi

	cd_safe "${startdir}"
	rm -rf "${srclinks}"
}

install_package() {
	(( ! INSTALL )) && return 0

	remove_deps || return $?
	RMDEPS=0

	if (( ! SPLITPKG )); then
		msg "$(gettext "Installing package %s with %s...")" "$pkgname" "$PACMAN -U"
	else
		msg "$(gettext "Installing %s package group with %s...")" "$pkgbase" "$PACMAN -U"
	fi

	local fullver pkgarch pkg pkglist
	(( ASDEPS )) && pkglist+=('--asdeps')
	(( NEEDED )) && pkglist+=('--needed')

	for pkg in ${pkgname[@]}; do
		fullver=$(get_full_version)
		pkgarch=$(get_pkg_arch $pkg)
		pkglist+=("$PKGDEST/${pkg}-${fullver}-${pkgarch}${PKGEXT}")

		if [[ -f "$PKGDEST/${pkg}-debug-${fullver}-${pkgarch}${PKGEXT}" ]]; then
			pkglist+=("$PKGDEST/${pkg}-debug-${fullver}-${pkgarch}${PKGEXT}")
		fi
	done

	if ! run_pacman -U "${pkglist[@]}"; then
		warning "$(gettext "Failed to install built package(s).")"
		return $E_INSTALL_FAILED
	fi
}

check_build_status() {
	local fullver pkgarch allpkgbuilt somepkgbuilt
	if (( ! SPLITPKG )); then
		fullver=$(get_full_version)
		pkgarch=$(get_pkg_arch)
		if [[ -f $PKGDEST/${pkgname}-${fullver}-${pkgarch}${PKGEXT} ]] \
				 && ! (( FORCE || SOURCEONLY || NOBUILD || NOARCHIVE)); then
			if (( INSTALL )); then
				warning "$(gettext "A package has already been built, installing existing package...")"
				install_package
				exit $?
			else
				error "$(gettext "A package has already been built. (use %s to overwrite)")" "-f"
				exit $E_ALREADY_BUILT
			fi
		fi
	else
		allpkgbuilt=1
		somepkgbuilt=0
		for pkg in ${pkgname[@]}; do
			fullver=$(get_full_version)
			pkgarch=$(get_pkg_arch $pkg)
			if [[ -f $PKGDEST/${pkg}-${fullver}-${pkgarch}${PKGEXT} ]]; then
				somepkgbuilt=1
			else
				allpkgbuilt=0
			fi
		done
		if ! (( FORCE || SOURCEONLY || NOBUILD || NOARCHIVE)); then
			if (( allpkgbuilt )); then
				if (( INSTALL )); then
					warning "$(gettext "The package group has already been built, installing existing packages...")"
					install_package
					exit $?
				else
					error "$(gettext "The package group has already been built. (use %s to overwrite)")" "-f"
					exit $E_ALREADY_BUILT
				fi
			fi
			if (( somepkgbuilt && ! PKGVERFUNC )); then
				error "$(gettext "Part of the package group has already been built. (use %s to overwrite)")" "-f"
				exit $E_ALREADY_BUILT
			fi
		fi
	fi
}

backup_package_variables() {
	local var
	for var in ${pkgbuild_schema_package_overrides[@]}; do
		local indirect="${var}_backup"
		eval "${indirect}=(\"\${$var[@]}\")"
	done
}

restore_package_variables() {
	local var
	for var in ${pkgbuild_schema_package_overrides[@]}; do
		local indirect="${var}_backup"
		if [[ -n ${!indirect} ]]; then
			eval "${var}=(\"\${$indirect[@]}\")"
		else
			unset ${var}
		fi
	done
}

run_single_packaging() {
	local pkgdir="$pkgdirbase/$pkgname"
	mkdir "$pkgdir"
	if [[ -n $1 ]] || (( PKGFUNC )); then
		run_package $1
	fi
	tidy_install
	lint_package || exit $E_PACKAGE_FAILED
	create_package
}

run_split_packaging() {
	local pkgname_backup=("${pkgname[@]}")
	backup_package_variables
	for pkgname in ${pkgname_backup[@]}; do
		run_single_packaging $pkgname
		restore_package_variables
	done
	pkgname=("${pkgname_backup[@]}")
}

check_distro_variables() {
	for i in depends optdepends conflicts provides replaces makedepends optdepends; do

		local variable_data="$(eval echo "\${${distro_release_name}_${i}[@]@Q}")"

		if [[ "${variable_data}" != "" ]]; then
			# For some reason the following command fails:
			#   eval declare "${i}"=(${variable_data})
			#
			# *soooo*, we just put it into one string (Presumably bash itself is
			# having an issue processing the above command).
			local declare_string="${i}=(${variable_data})"
			eval export "${declare_string}"
		fi

	done
}

usage() {
	printf "makepkg (%s)\n" "$makepkg_version"
	echo
	printf -- "$(gettext "Arch Linux build utility")\n"
	echo
	printf -- "$(gettext "Usage: %s [options]")\n" "makepkg"
	echo
	printf -- "$(gettext "Options:")\n"
	printf -- "$(gettext "  -A, --ignorearch    Ignore incomplete %s field in %s")\n" "arch" "$BUILDSCRIPT"
	printf -- "$(gettext "  -c, --clean         Clean up work files after build")\n"
	printf -- "$(gettext "  -C, --cleanbuild    Remove %s dir before building the package")\n" "\$srcdir/"
	printf -- "$(gettext "  -d, --nodeps        Skip all dependency checks")\n"
	printf -- "$(gettext "  -e, --noextract     Do not extract source files (use existing %s dir)")\n" "\$srcdir/"
	printf -- "$(gettext "  -f, --force         Overwrite existing package")\n"
	printf -- "$(gettext "  -g, --geninteg      Generate integrity checks for source files")\n"
	printf -- "$(gettext "  -h, --help          Show this help message and exit")\n"
	printf -- "$(gettext "  -i, --install       Install package after successful build")\n"
	printf -- "$(gettext "  -L, --log           Log package build process")\n"
	printf -- "$(gettext "  -m, --nocolor       Disable colorized output messages")\n"
	printf -- "$(gettext "  -o, --nobuild       Download and extract files only")\n"
	printf -- "$(gettext "  -p <file>           Use an alternate build script (instead of '%s')")\n" "$BUILDSCRIPT"
	printf -- "$(gettext "  -r, --rmdeps        Remove installed dependencies after a successful build")\n"
	printf -- "$(gettext "  -R, --repackage     Repackage contents of the package without rebuilding")\n"
	printf -- "$(gettext "  -s, --syncdeps      Install missing dependencies with %s")\n" "pacman"
	printf -- "$(gettext "  -S, --source        Generate a source-only tarball without downloaded sources")\n"
	printf -- "$(gettext "  -V, --version       Show version information and exit")\n"
	printf -- "$(gettext "  --allsource         Generate a source-only tarball including downloaded sources")\n"
	printf -- "$(gettext "  --check             Run the %s function in the %s")\n" "check()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --config <file>     Use an alternate config file (instead of '%s')")\n" "$confdir/makepkg.conf"
	printf -- "$(gettext "  --distrovars        Enable release-specific variables\n")"
	printf -- "$(gettext "  --holdver           Do not update VCS sources")\n"
	printf -- "$(gettext "  --key <key>         Specify a key to use for %s signing instead of the default")\n" "gpg"
	printf -- "$(gettext "  --noarchive         Do not create package archive")\n"
	printf -- "$(gettext "  --nocheck           Do not run the %s function in the %s")\n" "check()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --noprepare         Do not run the %s function in the %s")\n" "prepare()" "$BUILDSCRIPT"
	printf -- "$(gettext "  --nosign            Do not create a signature for the package")\n"
	printf -- "$(gettext "  --packagelist       Only list package filepaths that would be produced")\n"
	printf -- "$(gettext "  --printsrcinfo      Print the generated SRCINFO and exit")\n"
	printf -- "$(gettext "  --sign              Sign the resulting package with %s")\n" "gpg"
	printf -- "$(gettext "  --skipchecksums     Do not verify checksums of the source files")\n"
	printf -- "$(gettext "  --skipinteg         Do not perform any verification checks on source files")\n"
	printf -- "$(gettext "  --skippgpcheck      Do not verify source files with PGP signatures")\n"
	printf -- "$(gettext "  --verifysource      Download source files (if needed) and perform integrity checks")\n"
	echo

	if [[ "${makepkg_target_os}" == "arch" ]]; then
		printf "These options can be passed to pacman:\n"

		printf -- "$(gettext "  --asdeps         Install packages as non-explicitly installed")\n"
		printf -- "$(gettext "  --needed         Do not reinstall the targets that are already up to date")\n"
		printf -- "$(gettext "  --noconfirm      Do not ask for confirmation when resolving dependencies")\n"
		printf -- "$(gettext "  --noprogressbar  Do not show a progress bar when downloading files")\n"

		printf -- "$(gettext "If %s is not specified, %s will look for '%s'")\n" "-p" "makepkg" "$BUILDSCRIPT"
		echo
	fi
}

version() {
	printf "makepkg (%s) %s\n" "$makepkg_version"
	printf -- "    Copyright (c) 2021 Hunter Wittenborn <hunter@hunterwittenborn.com>.\n"
	printf -- "\n"
	printf -- "Thank you for the work done by the Arch Linux team in creating makepkg itself, without which makedeb wouldn't be possible.\n"
	printf -- "    2002-2006 Judd Vinet <jvinet@zeroflux.org>.\n"
	printf -- "    2006-2021 Pacman Development Team <pacman-dev@archlinux.org>.\n"
	printf '\n'
	printf -- "$(gettext "\
This is free software; see the source for copying conditions.\n\
There is NO WARRANTY, to the extent permitted by law.\n")"
}

# PROGRAM START

# ensure we have a sane umask set
umask 0022

# determine whether we have gettext; make it a no-op if we do not
if ! type -p gettext >/dev/null; then
	gettext() {
		printf "%s\n" "$@"
	}
fi

ARGLIST=("$@")

# Parse Command Line Options.
OPT_SHORT="AcCdefFghiLmop:rRsSV"
OPT_LONG=('allsource' 'check' 'clean' 'cleanbuild' 'config:' 'force' 'geninteg'
          'help' 'holdver' 'ignorearch' 'install' 'key:' 'log' 'noarchive' 'nobuild'
          'nocolor' 'nocheck' 'nodeps' 'noextract' 'noprepare' 'nosign' 'packagelist'
          'printsrcinfo' 'repackage' 'rmdeps' 'sign' 'skipchecksums' 'skipinteg'
          'skippgpcheck' 'source' 'syncdeps' 'verifysource' 'version'

		  'distrovars' 'skip-makedeb-warning' 'format-makedeb')

# Pacman options
if [[ "${makepkg_target_os}" == "arch" ]]; then
	OPT_LONG+=('asdeps' 'needed' 'noconfirm' 'noprogressbar')
fi

if ! parseopts "$OPT_SHORT" "${OPT_LONG[@]}" -- "$@"; then
	exit $E_INVALID_OPTION
fi
set -- "${OPTRET[@]}"
unset OPT_SHORT OPT_LONG OPTRET

while true; do
	case "$1" in
		# Pacman Options
		--asdeps)                ASDEPS=1;;
		--needed)                NEEDED=1;;
		--noconfirm)             PACMAN_OPTS+=("--noconfirm") ;;
		--noprogressbar)         PACMAN_OPTS+=("--noprogressbar") ;;

		# Makepkg Options
		--allsource)             BUILDPKG=0 SOURCEONLY=2 ;;
		-A|--ignorearch)         IGNOREARCH=1 ;;
		-c|--clean)              CLEANUP=1 ;;
		-C|--cleanbuild)         CLEANBUILD=1 ;;
		--check)                 RUN_CHECK='y' ;;
		--config)                shift; MAKEPKG_CONF=$1 ;;
		-d|--nodeps)             NODEPS=1 ;;
		-e|--noextract)          NOEXTRACT=1 ;;
		-f|--force)              FORCE=1 ;;
		-F)                      INFAKEROOT=1 ;;
		# generating integrity checks does not depend on architecture
		-g|--geninteg)           BUILDPKG=0 GENINTEG=1 IGNOREARCH=1;;
		--holdver)               HOLDVER=1 ;;
		-i|--install)            INSTALL=1 ;;
		--key)                   shift; GPGKEY=$1 ;;
		-L|--log)                LOGGING=1 ;;
		-m|--nocolor)            USE_COLOR='n'; PACMAN_OPTS+=("--color" "never") ;;
		--noarchive)             NOARCHIVE=1 ;;
		--nocheck)               RUN_CHECK='n' ;;
		--noprepare)             RUN_PREPARE='n' ;;
		--nosign)                SIGNPKG='n' ;;
		-o|--nobuild)            BUILDPKG=0 NOBUILD=1 ;;
		-p)                      shift; BUILDFILE=$1 ;;
		--packagelist)           BUILDPKG=0 PACKAGELIST=1 IGNOREARCH=1;;
		--printsrcinfo)          BUILDPKG=0 PRINTSRCINFO=1 IGNOREARCH=1;;
		-r|--rmdeps)             RMDEPS=1 ;;
		-R|--repackage)          REPKG=1 ;;
		--sign)                  SIGNPKG='y' ;;
		--skipchecksums)         SKIPCHECKSUMS=1 ;;
		--skipinteg)             SKIPCHECKSUMS=1; SKIPPGPCHECK=1 ;;
		--skippgpcheck)          SKIPPGPCHECK=1;;
		-s|--syncdeps)           DEP_BIN=1 ;;
		-S|--source)             BUILDPKG=0 SOURCEONLY=1 ;;
		--verifysource)          BUILDPKG=0 VERIFYSOURCE=1 ;;

		-h|--help)               usage; exit $E_OK ;;
		-V|--version)            version; exit $E_OK ;;

		--distrovars)            export DISTROVARIABLES='y' ;;
		--format-makedeb)        export FORMAT_MAKEDEB=1 ;;
		--)                      shift; break ;;
	esac
	shift
done

# Check if '--skip-makedeb-warning' was passed
if ! (( ${FORMAT_MAKEDEB} )); then
	colorize

	error "This program is for internal use by makedeb, and should not be called directly."
	error "The changes to this fork of makepkg are not well documented, and you may run into issues."
	error "If you'd like to continue, use the '--format-makedeb' option."
	exit 1
fi

# attempt to consume any extra argv as environment variables. this supports
# overriding (e.g. CC=clang) as well as overriding (e.g. CFLAGS+=' -g').
extra_environment=()
while [[ $1 ]]; do
	if [[ $1 = [_[:alpha:]]*([[:alnum:]_])?(+)=* ]]; then
		extra_environment+=("$1")
	fi
	shift
done

# setup signal traps
trap 'clean_up' 0
for signal in TERM HUP QUIT; do
	trap "trap_exit $signal \"$(gettext "%s signal caught. Exiting...")\" \"$signal\"" "$signal"
done
trap 'trap_exit INT "$(gettext "Aborted by user! Exiting...")"' INT
trap 'trap_exit USR1 "$(gettext "An unknown error has occurred. Exiting...")"' ERR

load_makepkg_config

# override settings from extra variables on commandline, if any
if (( ${#extra_environment[*]} )); then
	export "${extra_environment[@]}"
fi

# canonicalize paths and provide defaults if anything is still undefined
for var in PKGDEST SRCDEST SRCPKGDEST LOGDEST BUILDDIR; do
	printf -v "$var" '%s' "$(canonicalize_path "${!var:-$startdir}")"
done
unset var
PACKAGER=${PACKAGER:-"Unknown Packager"}

# set pacman command if not already defined
PACMAN=${PACMAN:-pacman}
# save full path to command as PATH may change when sourcing /etc/profile
PACMAN_PATH=$(type -P $PACMAN)

# check if messages are to be printed using color
if [[ -t 2 && $USE_COLOR != "n" ]] && check_buildenv "color" "y"; then
	colorize
else
	unset ALL_OFF BOLD BLUE GREEN RED YELLOW
fi


# check makepkg.conf for some basic requirements
lint_config || exit $E_CONFIG_ERROR


# check that all settings directories are user-writable
if ! ensure_writable_dir "BUILDDIR" "$BUILDDIR"; then
	plainerr "$(gettext "Aborting...")"
	exit $E_FS_PERMISSIONS
fi

if (( ! (NOBUILD || GENINTEG) )) && ! ensure_writable_dir "PKGDEST" "$PKGDEST"; then
	plainerr "$(gettext "Aborting...")"
	exit $E_FS_PERMISSIONS
fi

if ! ensure_writable_dir "SRCDEST" "$SRCDEST" ; then
	plainerr "$(gettext "Aborting...")"
	exit $E_FS_PERMISSIONS
fi

if (( SOURCEONLY )); then
	if ! ensure_writable_dir "SRCPKGDEST" "$SRCPKGDEST"; then
		plainerr "$(gettext "Aborting...")"
		exit $E_FS_PERMISSIONS
	fi

	# If we're only making a source tarball, then we need to ignore architecture-
	# dependent behavior.
	IGNOREARCH=1
fi

if (( LOGGING )) && ! ensure_writable_dir "LOGDEST" "$LOGDEST"; then
	plainerr "$(gettext "Aborting...")"
	exit $E_FS_PERMISSIONS
fi

if (( ! INFAKEROOT )); then
	if (( EUID == 0 )); then
		error "$(gettext "Running %s as root is not allowed as it can cause permanent,\n\
catastrophic damage to your system.")" "makepkg"
		exit $E_ROOT
	fi
else
	if [[ -z $FAKEROOTKEY ]]; then
		error "$(gettext "Do not use the %s option. This option is only for internal use by %s.")" "'-F'" "makepkg"
		exit $E_INVALID_OPTION
	fi
fi

unset pkgname "${pkgbuild_schema_strings[@]}" "${pkgbuild_schema_arrays[@]}"
unset "${known_hash_algos[@]/%/sums}"
unset -f pkgver prepare build check package "${!package_@}"
unset "${!makedepends_@}" "${!depends_@}" "${!source_@}" "${!checkdepends_@}"
unset "${!optdepends_@}" "${!conflicts_@}" "${!provides_@}" "${!replaces_@}"
unset "${!cksums_@}" "${!md5sums_@}" "${!sha1sums_@}" "${!sha224sums_@}"
unset "${!sha256sums_@}" "${!sha384sums_@}" "${!sha512sums_@}" "${!b2sums_@}"

BUILDFILE=${BUILDFILE:-$BUILDSCRIPT}
if [[ ! -f $BUILDFILE ]]; then
	error "$(gettext "%s does not exist.")" "$BUILDFILE"
	exit $E_PKGBUILD_ERROR

else
	if [[ $(<"$BUILDFILE") = *$'\r'* ]]; then
		error "$(gettext "%s contains %s characters and cannot be sourced.")" "$BUILDFILE" "CRLF"
		exit $E_PKGBUILD_ERROR
	fi

	if [[ ! $BUILDFILE -ef $PWD/${BUILDFILE##*/} ]]; then
		error "$(gettext "%s must be in the current working directory.")" "$BUILDFILE"
		exit $E_PKGBUILD_ERROR
	fi

	if [[ ${BUILDFILE:0:1} != "/" ]]; then
		BUILDFILE="$startdir/$BUILDFILE"
	fi
	source_buildfile "$BUILDFILE"
fi

pkgbase=${pkgbase:-${pkgname[0]}}

# check the PKGBUILD for some basic requirements
lint_pkgbuild || exit $E_PKGBUILD_ERROR

if (( !SOURCEONLY && !PRINTSRCINFO )); then
	merge_arch_attrs
fi

basever=$(get_full_version)

if [[ $BUILDDIR -ef "$startdir" ]]; then
	srcdir="$BUILDDIR/src"
	pkgdirbase="$BUILDDIR/pkg"
else
	srcdir="$BUILDDIR/$pkgbase/src"
	pkgdirbase="$BUILDDIR/$pkgbase/pkg"

fi

# set pkgdir to something "sensible" for (not recommended) use during build()
pkgdir="$pkgdirbase/$pkgbase"

if (( GENINTEG )); then
	mkdir -p "$srcdir"
	chmod a-s "$srcdir"
	cd_safe "$srcdir"
	download_sources novcs allarch >&2
	generate_checksums
	exit $E_OK
fi

if have_function pkgver; then
	PKGVERFUNC=1
fi

# check we have the software required to process the PKGBUILD
check_software || exit $E_MISSING_MAKEPKG_DEPS

if (( ${#pkgname[@]} > 1 )) || have_function package_${pkgname}; then
	SPLITPKG=1
fi

# test for available PKGBUILD functions
if have_function prepare; then
	# "Hide" prepare() function if not going to be run
	if [[ $RUN_PREPARE != "n" ]]; then
		PREPAREFUNC=1
	fi
fi
if have_function build; then
	BUILDFUNC=1
fi
if have_function check; then
	# "Hide" check() function if not going to be run
	if [[ $RUN_CHECK = 'y' ]] || { ! check_buildenv "check" "n" && [[ $RUN_CHECK != "n" ]]; }; then
		CHECKFUNC=1
	fi
fi
if have_function package; then
	PKGFUNC=1
fi

# check if gpg signature is to be created and if signing key is valid
if { [[ -z $SIGNPKG ]] && check_buildenv "sign" "y"; } || [[ $SIGNPKG == 'y' ]]; then
	SIGNPKG='y'
	if ! gpg --list-secret-key ${GPGKEY:+"$GPGKEY"} &>/dev/null; then
		if [[ ! -z $GPGKEY ]]; then
			error "$(gettext "The key %s does not exist in your keyring.")" "${GPGKEY}"
		else
			error "$(gettext "There is no key in your keyring.")"
		fi
		exit $E_PRETTY_BAD_PRIVACY
	fi
fi

if (( PACKAGELIST )); then
	print_all_package_names
	exit $E_OK
fi

if (( PRINTSRCINFO )); then
	write_srcinfo_content
	exit $E_OK
fi

if (( ! PKGVERFUNC )); then
	check_build_status
fi

# Run the bare minimum in fakeroot
if (( INFAKEROOT )); then
	if (( SOURCEONLY )); then
		create_srcpackage
		msg "$(gettext "Leaving %s environment.")" "fakeroot"
		exit $E_OK
	fi

	prepare_buildenv

	chmod 755 "$pkgdirbase"
	if (( ! SPLITPKG )); then
		run_single_packaging
	else
		run_split_packaging
	fi

	create_debug_package

	msg "$(gettext "Leaving %s environment.")" "fakeroot"
	exit $E_OK
fi

msg "$(gettext "Making package: %s")" "$pkgbase $basever ($(date +%c))"

# if we are creating a source-only package, go no further
if (( SOURCEONLY )); then
	if [[ -f $SRCPKGDEST/${pkgbase}-${basever}${SRCEXT} ]] \
			&& (( ! FORCE )); then
		error "$(gettext "A source package has already been built. (use %s to overwrite)")" "-f"
		exit $E_ALREADY_BUILT
	fi

	# Get back to our src directory so we can begin with sources.
	mkdir -p "$srcdir"
	chmod a-s "$srcdir"
	cd_safe "$srcdir"
	if (( SOURCEONLY == 2 )); then
		download_sources allarch
	elif ( (( ! SKIPCHECKSUMS )) || \
			( (( ! SKIPPGPCHECK )) && source_has_signatures ) ); then
		download_sources allarch novcs
	fi
	check_source_integrity all
	cd_safe "$startdir"

	enter_fakeroot

	if [[ $SIGNPKG = 'y' ]]; then
		msg "$(gettext "Signing package...")"
		create_signature "$SRCPKGDEST/${pkgbase}-$(get_full_version)${SRCEXT}"
	fi

	msg "$(gettext "Source package created: %s")" "$pkgbase ($(date +%c))"
	exit $E_OK
fi

if (( NODEPS || ( VERIFYSOURCE && !DEP_BIN ) )); then
	if (( NODEPS )); then
		warning "$(gettext "Skipping dependency checks.")"
	fi
else
	if (( RMDEPS && ! INSTALL )); then
		original_pkglist=($(run_pacman -Qq))    # required by remove_dep
	fi
	deperr=0

	msg "$(gettext "Checking runtime dependencies...")"
	resolve_deps ${depends[@]} || deperr=1

	if (( RMDEPS && INSTALL )); then
		original_pkglist=($(run_pacman -Qq))    # required by remove_dep
	fi

	msg "$(gettext "Checking buildtime dependencies...")"
	if (( CHECKFUNC )); then
		resolve_deps "${makedepends[@]}" "${checkdepends[@]}" || deperr=1
	else
		resolve_deps "${makedepends[@]}" || deperr=1
	fi

	if (( RMDEPS )); then
		current_pkglist=($(run_pacman -Qq))    # required by remove_deps
	fi

	if (( deperr )); then
		error "$(gettext "Could not resolve all dependencies.")"
		exit $E_INSTALL_DEPS_FAILED
	fi
fi

# get back to our src directory so we can begin with sources
mkdir -p "$srcdir"
chmod a-s "$srcdir"
cd_safe "$srcdir"

if (( !REPKG )); then
	if (( NOEXTRACT && ! VERIFYSOURCE )); then
		warning "$(gettext "Using existing %s tree")" "\$srcdir/"
	else
		download_sources
		check_source_integrity
		(( VERIFYSOURCE )) && exit $E_OK

		if (( CLEANBUILD )); then
			msg "$(gettext "Removing existing %s directory...")" "\$srcdir/"
			rm -rf "$srcdir"/*
		fi

		extract_sources
		if (( PREPAREFUNC )); then
			run_prepare
		fi
		if (( REPRODUCIBLE )); then
			# We have activated reproducible builds, so unify source times before
			# building
			find "$srcdir" -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
		fi
	fi

	if (( PKGVERFUNC )); then
		update_pkgver
		basever=$(get_full_version)
		check_build_status
	fi
fi

if (( NOBUILD )); then
	msg "$(gettext "Sources are ready.")"
	exit $E_OK
else
	# clean existing pkg directory
	if [[ -d $pkgdirbase ]]; then
		msg "$(gettext "Removing existing %s directory...")" "\$pkgdir/"
		rm -rf "$pkgdirbase"
	fi
	mkdir -p "$pkgdirbase"
	chmod a-srw "$pkgdirbase"
	cd_safe "$startdir"

	prepare_buildenv

	if (( ! REPKG )); then
		(( BUILDFUNC )) && run_build
		(( CHECKFUNC )) && run_check
		cd_safe "$startdir"
	fi

	enter_fakeroot

	create_package_signatures || exit $E_PRETTY_BAD_PRIVACY
fi

# if inhibiting archive creation, go no further
if (( NOARCHIVE )); then
	msg "$(gettext "Package directory is ready.")"
	exit $E_OK
fi

msg "$(gettext "Finished making: %s")" "$pkgbase $basever ($(date +%c))"

install_package && exit $E_OK || exit $E_INSTALL_FAILED
