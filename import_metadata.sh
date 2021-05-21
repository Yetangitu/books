#!/bin/bash
#shellcheck disable=SC2034,SC1090
#
# import_metadata - import metadata to libgen/libgen_fiction
#
# input: a [single line of|file containg] CSV-ordered metadata

shopt -s extglob  
trap "trap_error" TERM
trap "trap_clean" EXIT
export TOP_PID=$$

version="0.1.0"
release="20210518"

functions="$(dirname "$0")/books_functions"
if [ -f "$functions" ]; then
        source "$functions"
else
        echo "$functions not found"
        exit 1
fi

main () {

	exlock now || exit 1

	coproc coproc_ddc { coproc_ddc; }
	coproc coproc_fast { coproc_fast; } 

        # PREFERENCES
        config=${XDG_CONFIG_HOME:-$HOME/.config}/books.conf

        dbhost="localhost"
        dbport="3306"
        db="libgen"
        dbuser="libgen"

	tmpdir=$(mktemp -d '/tmp/import_metadata.XXXXXX')
	update_sql="${tmpdir}/update_sql"

	# input field filters
	declare -A filter=(
		[md5]=filter_md5
		[ddc]=filter_ddc
		[lcc]=filter_ddc
		[nlm]=filter_ddc
		[fast]=filter_fast
		[author]=filter_fast
		[title]=filter_fast
	)

	# redirect OCLC [key] to field
	declare -A redirect=(
		[fast]="tags"
	)

	# used to get index for field / field for index
	keys="md5 ddc lcc nlm fast author title"
	declare -A headers
	index=0
	for key in $keys;do
		headers["$key"]=$index
		((index++))
	done

	declare -A tables=(
		[libgen]="updated"
		[libgen_fiction]="fiction"
	)

        # source config file if it exists
        [[ -f ${config} ]] && source "${config}"

	declare -a csvdata
	declare -a csv

	while getopts "d:f:F:ns:vh" OPTION; do
		case $OPTION in
			d)
				if [ -n "${tables[$OPTARG]}" ]; then
					db="$OPTARG"
				else
					exit_with_error "-d $OPTARG: no such database"
				fi
				;;
			f)
				for n in $OPTARG; do
					if [ -n "${headers[$n]}" ]; then
						fields+="${fields:+ }$n"
					else
						exit_with_error "no such field: $n"
					fi
				done
				;;
			F)
				if [ -f "$OPTARG" ]; then
					csvfile="$OPTARG"
				else
					exit_with_error "-f $OPTARG: no such file"
				fi
				;;
			s)
				sqlfile="$OPTARG"
				if ! touch "$sqlfile"; then
					exit_with_error "-s $OPTARG: can not write to file"
				fi
				;;
			n)
				dry_run=1
				;;
			v)
				((verbose++))
				;;
			h)
				help
				exit
				;;
			*)
				exit_with_error "unknown option: -$OPTION"
				;;
		esac
	done

	shift $((OPTIND-1))

	[[ -z "$db" ]] && exit_with_error "no database defined, use -d database"
	[[ -z "$fields" ]] && exit_with_error "no fields defined, use -f 'field1 field2' or -f field1 -f field2"

	if [ -z "$dry_run" ]; then
		declare -A current_fields='('$(get_current_fields "$db")')'
		for field in $fields; do
			[[ -n "${redirect[$field]}" ]] && field="${redirect[$field]}"
			if [[ ! "${!current_fields[*]}" =~ "${field,,}" ]]; then
				exit_with_error "field $field not in database $db"
			fi
		done
	fi

	if [[ -n "$csvfile" ]]; then
		readarray -t csvdata < <(cat "$csvfile")
	else
		readarray -t csvdata <<< "$*"
	fi

	printf "start transaction;\n" > "${update_sql}"

	for line in "${csvdata[@]}"; do
		readarray -d',' -t csv <<< "$line"

		if [[ "$verbose" -ge 2 ]]; then
			index=0
			for key in $keys; do
				echo "${key^^}: $(${filter[$key]} "$key")"
				((index++))
			done
		fi

		sql="$(build_sql)"

		printf "$sql\n" >> "$update_sql"

		if [[ "$verbose" -ge 3 ]]; then
			echo "$sql"
		fi

		[[ -n "$sqlfile" ]] && printf "$sql\n" >> "$sqlfile"

		unset key
		unset sql
		csv=()
	done

	printf "commit;\n" >> "$update_sql"
	[[ -z "$dry_run" ]] && dbx "$db" < "$update_sql"
}

filter_md5 () {
	field="$1"
	printf "${csv[${headers[$field]}]}"
}

filter_ddc () {
	field="$1"

	# without coprocess
        # echo "${csv[${headers[$field]}]}"|sed 's/"//g;s/[[:blank:]]\+/,/g'
	
	# with coprocess (30% faster)
        printf "${csv[${headers[$field]}]}\n" >&${coproc_ddc[1]}
	IFS= read -ru ${coproc_ddc[0]} value
	printf "$value"
}

coproc_ddc () {
        sed -u 's/"//g;s/[[:blank:]]\+/,/g'
}


filter_fast () {
	field="$1"

	# without coprocess
        # echo "${csv[${headers[$field]}]}"|base64 -d|sed -u 's/\(["\\'\'']\)/\\\1/g;s/\r/\\r/g;s/\n/\\n/g;s/\t/\\t/g'

	# with coprocess (30% faster)
	# base64 can not be used as a coprocess due to its uncurable buffering addiction
	value=$(printf "${csv[${headers[$field]}]}"|base64 -d)
       	printf "$value\n" >&${coproc_fast[1]}
	IFS= read -ru ${coproc_fast[0]} value
	printf "$value"
}

coproc_fast () {
        sed -u 's/\(["\\'\'']\)/\\\1/g;s/\r/\\r/g;s/\n/\\n/g;s/\t/\\t/g'
}


get_field () {
	field="$1"
	value="${csv[${headers[$field]}]}"
	if [ -n "${filters[$field]}" ]; then
		printf "$value"|eval "${filters[$field]}"
	else
		printf "$value"
	fi
}

get_current_fields () {
	db="$1"
        for table in "${tables[$db]}"; do
                dbx "$db" "describe $table;"|awk '{printf "[%s]=%s ",tolower($1),"'$table'"}'
        done
}

build_sql () {
	sql=""
	for field in $fields; do
		data=$(${filter[$field]} "$field")
		if [ -n "$data" ]; then
			[[ -n "${redirect[$field]}" ]]  && field="${redirect[$field]}"
			sql+="${sql:+,}${field^^}='${data}'"
		fi
	done

	if [ -n "$sql" ]; then
		printf "update ${tables[$db]} set $sql where MD5='$(${filter['md5']} md5)';"
	fi
}

cleanup () {
        rm -rf "${tmpdir}"
}

# HELP

help ()  {
        echo "$(basename "$(readlink -f "$0")")" "version $version"
        cat <<- EOHELP

	Use: import_metadata [OPTIONS] -d database -f "field1 field2" [-F CSVDATAFILE | single line of csv data ]

	Taking either a single line of CSV-formatted data or a file containing
	such data, this tool can be used to update a libgen / libgen_fiction
	database with fresh metadata. It can also be used to produce SQL (using
	the -s sqlfile option) which can be used to update multiple database
	instances.

	CSV data format:

	   $(hkeys=${keys^^};echo ${hkeys// /,})

	CSV field names are subject to redirection to database field names,
	currently these redirections are active (CSV -> DB):

	$(for field in "${!redirect[@]}";do echo "   ${field^^} -> ${redirect[$field]^^}";done)

	OPTIONS:

	 	-d DB	define which database to use (libgen/libgen_fiction)

	 	-f 'field1 field2'
	 	-f field1 -f field2

	 		define which fields to update

	 	-F CSVFILE

	 		define CSV input file

	 	-s SQLFILE

	 		write SQL to SQLFILE

	 	-n	do not update database
	 		use with -s SQLFILE to produce SQL for later use
	 		use with -vv to see data from CSVFILE
	 		use with -vvv to see SQL

	 	-v	verbosity
	 		repeat to increase verbosity

	 	-h	this help message

	Examples

	$ import_metadata -d libgen -F csv/update-0000 -f 'ddc lcc fast'

	update database 'libgen' using data from CSV file csv/update-0000,
	fields DDC, LCC and FAST (which is redirected to libgen.Tags)

	$ for f in csv/update-*;do
	      import_metadata -d libgen -s sql/metadata.sql -n -f 'ddc lcc fast' -F "\$f"
	  done

	create SQL (-s sql/metadata.sql) to update database using fields
	DDC, LCC and FAST from all files matching glob csv/update-*,
	do not update database (-n option)
	

	EOHELP
}

exlock prepare || exit 1

main "$@"
