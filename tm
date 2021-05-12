#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090,SC2207

shopt -s extglob

export TOP_PID=$$

version="0.1.2"
release="20210512"

main () {
	config=${XDG_CONFIG_HOME:-$HOME/.config}/tm.conf
	netrc=~/.tm-netrc
	tm_host="localhost:4081"
	# source config file if it exists
        [[ -f ${config} ]] && source "${config}"

	declare -a commands=($(declare -F|grep tm_|sed -e 's/.*tm_\(\S\+\).*/\1/'))
	declare -a programs=($(declare -F|grep tm_|sed -e 's/.*\(tm_\S\+\).*/\1/;s/_/-/g'))


	while getopts "a:chH:kln:" OPTION
	do
		case $OPTION in
			k)
				create_symlinks
				exit
				;;
			a)
				tm_add "${OPTARG}"
				exit
				;;
			l)
				tm_ls
				exit
				;;
			n)
				netrc="${OPTARG}"
				;;
			H)
				tm_host="${OPTARG}"
				;;
			c)
				if [[ ! -f "${config}" ]]; then
					cat <<-EOT > "${config}"
					netrc="$netrc"
					tm_host="$tm_host"
					EOT
				else
					exit_with_error "-c: config file ${config} exists, either remove it or edit it directly"
				fi
				;;
			h)
				help
				exit
				;;
			*)
				exit_with_error "unknown option $OPTION"
				;;
		esac
	done

	# shift out options
	shift $((OPTIND-1))

	cmd="${1//-/_}"
	program=$(basename "$0")

	IFS='|'
	if [[ $cmd =~ ${commands[*]} ]]; then
		unset IFS
		shift
		tm_"$cmd" "$@"
	elif [[ $program =~ ${programs[*]} ]]; then
		unset IFS
		${program//-/_} "$@"
	else
		unset IFS
		exit_with_error "no such command: $cmd\navailable commands: ${commands[*]//_/-}"
	fi
}

# commands

tm_cmd () {
	if [[ -n $(which transmission-remote) ]]; then
		transmission-remote "$tm_host" -N "$netrc" "$@"
	else
		exit_with_error "transmission-remote not found, please install it first (apt install transmission-cli)"
	fi
}

tm_help () {
	tm_cmd -h
}

tm_add () {
	tm_cmd -a "$@"
}

tm_add_selective () {
	torrent="$1"
	shift
	files="${*,,}"

	keep=0
	count=0

	if [[ -z "$torrent" || -z "$files" ]]; then
		echo 'use: tm-add-selective <torrent_file> <file1>[,file2,file3,file4...]'
		exit 1
	fi

	check_torrent "$torrent"

	tm_cmd --start-paused
	btih=$(tm_torrent_hash "$torrent")

	# check if torrent is already downloading
	if tm_active "$btih"; then
		running=1
		tm_stop "$btih"
	else
		tm_add "$torrent"
	fi

	if tm_info "$btih" > /dev/null; then
		count=$(tm_file_count "$btih")
		# if the torrent only has 1 file it does not make sense to do a selective download...
		if [[ $count -gt 1 ]]; then
			if [[ $running -eq 0 ]]; then
				# need to keep at least 1 file active, otherwise transmission removes the torrent
				tm_cmd -t "$btih" -G 1-$((count-1))
			fi
			while read -r id; do
				[[ $id -eq 0 ]] && keep=1
				tm_cmd -t "$btih" -g "$id"
			done < <(tm_cmd -t "$btih" -f|grep -E "${files/,/|}"|cut -d ':' -f 1)
			[[ $keep -eq 0 && $running -eq 0 ]] && tm_cmd -t "$btih" -G 0
		fi
	else
		echo "error adding torrent"
		exit 1
	fi
	tm_cmd --no-start-paused
	tm_start "$btih"
}

tm_remove () {
	tm_cmd -t "$@" -r
}

tm_start () {
	if tm_active "$@"; then
		tm_cmd -t "$@" -s
	fi
}

tm_stop () {
	tm_cmd -t "$@" -S
}

tm_info () {
	tm_cmd -t "$@" -i
}

tm_files () {
	tm_cmd -t "$@" -f
}

tm_ls () {
	tm_cmd -l
}

tm_file_count () {
	tm_files "$1"|head -1|sed 's/.* (\([[:digit:]]\+\) files):/\1/'
}

tm_active () {
	tm_cmd -t "$@" -ip|grep -q Address
}

# torrent file related commands

tm_torrent_show () {
	check_torrent "$@"
	transmission-show "$@"
}

tm_torrent_files () {
	tm_torrent_show "$@"|awk '/^FILES/ {start=1}; NF>1 && start==1 {print $0}'|sed -e 's/^\s\+\(.*\) ([0-9.]\+ .B)$/\1/'
}

tm_torrent_hash () {
	tm_torrent_show "$@"|awk ' /^\s+Hash:/ {print $2}'
}

# helper functions

exit_with_error () {
        echo -e "$(basename "$0"): $*" >&2

        kill -s TERM $TOP_PID
}

check_torrent () {
	if ! (file "$1"|grep -i bittorrent)>/dev/null; then
                exit_with_error "$1 is not a torrent file"
        fi
}

create_symlinks () {
        basedir="$(dirname "$0")"
        sourcefile="$(readlink -e "$0")"
	prefix=$(basename "$sourcefile")
        for cmd in "${commands[@]}"; do
		name="${prefix}-${cmd//_/-}"
                if [[ ! -e "$basedir/$name" ]]; then
                        ln -s "$sourcefile" "$basedir/$name"
                fi
        done

        exit
}

help () {
        sourcefile="$(readlink -e "$0")"
	prefix=$(basename "$sourcefile")
	echo "$(basename "$(readlink -f "$0")")" "version $version"
        cat <<- EOF

	Use: $prefix COMMAND OPTIONS [parameters]
	     $prefix-COMMAND OPTIONS [parameters]
	
	A helper script for transmission-remote and related tools, adding some
	functionality like selective download etc.

	PROGRAMS/COMMANDS

	EOF

	for cmd in "${programs[@]}"; do
		echo -e "    $cmd\r\t\t\t${cmd/$prefix-}"
	done

	cat <<- EOF

	OPTIONS

	    -k		create symbolic links
	                creates links to all supported commands
	                e.g. $prefix-cmd, $prefix-ls, $prefix-add, ...
	                links are created in the directory where $prefix resides

	    -n NETRC	set netrc ($netrc)

	    -H HOST	set host ($tm_host)

	    -c		create a config file using current settings (see -n, -H)

	    -l		execute command 'ls'

	    -a TORR	execute command 'add'

	    -h		this help message

	EXAMPLES

	In all cases it is possible to replace $prefix-COMMAND with $prefix COMMAND

	show info about running torrents:

	    $ $prefix-ls

	add a torrent or a magnet link:

	    $prefix-add /path/to/torrent/file.torrent
	    $prefix-add 'magnet:?xt=urn:btih:123...'

	add a torrent and selectivly download two files
	this only works with torrent files (i.e. not magnet links) for now

	    $prefix-add-selective /path/to/torrent/file.torrent filename1,filename2

	show information about a running torrent, using its btih or ID:

	    $prefix-show f0a7524fe95910da462a0d1b11919ffb7e57d34a
	    $prefix-show 21

	show files for a running torrent identified by btih (can also use ID)

	    $prefix-files f0a7524fe95910da462a0d1b11919ffb7e57d34a

	stop a running torrent, using its ID (can also use btih)

	    $prefix-stop 21

	get btih for a torrent file

	    $prefix-torrent-hash /path/to/torrent/file.torrent

	remove a torrent from transmission

	    $prefix-remove 21

	execute any transmission-remote command - notice the double dash
	see man transmission-remote for more info on supported commands
	

	    $prefix-cmd -- -h
	    $prefix cmd -h

	
	CONFIGURATION FILES

	    $config

	$prefix can be configured by editing the script itself or the configuration file:

	        netrc=~/.tm-netrc
	        tm_host="transmission-host.example.org:4081"
	
	values set in the configuration file override those in the script

	EOF
}

main "$@"
