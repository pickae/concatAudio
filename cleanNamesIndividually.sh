#!/bin/bash
# Library function: source this file to make cleanNamesIndividually available.
#
# cleanNamesIndividually <rawName>
#   Cleans a single name and splits off a leading number/date prefix.
#   Input  : $1 = the raw name to clean
#   Output : results are returned in memory (no temp files) via the globals
#            RET_PREFIX : the detected leading prefix (may be empty)
#            RET_NAME   : the cleaned name with the prefix removed

cleanNamesIndividually() {

    local newName="$1"

    # special characters to replace with spaces
    newName=${newName//"."/ }
    newName=${newName//" - "/ }
    newName=${newName//"_"/ }
    newName=${newName//"\`"/ }

    # special characters to wipe
    newName=${newName//"'"/}
    newName=${newName//"\""/}
    newName=${newName//"”"/}
    newName=${newName//"“"/}
    newName=${newName//[$'\t\r\n']/}

    # e.g. Track01 to Track 01
    # this makes it easier later to crop the common prefix "Track"
    newName=${newName//"Track"/"Track "}
    newName=${newName//"Piste"/"Piste "}

    # determine prefix which could be date or number
    # corner case : date plus number, the number will be kept as part of name
    # splitting the prefixes is needed to later cleanup the names across all chapters
    # and needed because certain prefixes are better not put into chapter names
    #
    # each rule is "offset length strip regex": look at the fixed-width slice
    # newName[offset:length] and, if it matches the regex, take that slice as the
    # prefix and drop the first "strip" characters of the name.
    # the rules are ordered from the longest number down to the shortest, because
    # checking the longest first avoids mangling the numbers; first match wins.
    local prefix=""
    local rule off len strip pat candidate
    for rule in \
        "0 8 8 ^[1-2][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$" \
        "0 5 5 ^[0-9][0-9]-[0-9][0-9]$" \
        "0 4 4 ^[0-9][0-9][0-9][0-9]$" \
        "0 3 3 ^[0-9][0-9][0-9]$" \
        "0 2 2 ^[0-9][0-9]$" \
        "1 2 4 ^[0-9][0-9]$" \
        "0 1 1 ^[0-9]$"
    do
        read -r off len strip pat <<< "$rule"
        candidate="${newName:off:len}"
        if [[ $candidate =~ $pat ]]; then
            prefix="$candidate"
            newName="${newName:strip}"
            break
        fi
    done

    # remove double spaces and trailing spaces and dashes
    newName=$(echo "$newName" | xargs)
    newName=$(echo "$newName" | sed 's/[-]*$//g')
    newName=$(echo "$newName" | sed 's/[.]*$//g')
    newName=$(echo "$newName" | sed 's/[/]*$//g')
    newName=$(echo "$newName" | sed 's/[_]*$//g')
    newName=$(echo "$newName" | xargs)

    # return the cleaned name and detected prefix in memory
    # callers read these global variables instead of reading text files
    RET_PREFIX="$prefix"
    RET_NAME="$newName"
}
