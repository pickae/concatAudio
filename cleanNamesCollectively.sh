#!/bin/bash
# Library function: source this file to make cleanNamesCollectively available.
#
# cleanNamesCollectively <srcArrayName> <dstArrayName>
#   Removes the longest common (case-insensitive) leading and trailing affixes
#   shared by all names. Works entirely in memory (no temp files): arrays are
#   passed and returned by name via namerefs.
#   Input  : $1 = name of the input array of names
#   Output : $2 = name of the array to receive the cleaned names

cleanNamesCollectively() {

    # operate on in-memory arrays passed by name
    # $1 : name of the input array, $2 : name of the output array
    local -n __src="$1"
    local -n __dst="$2"
    local _items=("${__src[@]}")

    # case insensitive:
    # the common affixes are detected on a lower-cased copy of the names and
    # then stripped from the original names by length, so names that differ
    # only in case still share (and lose) the same common prefix and suffix
    local _lower=("${_items[@],,}")

    # find the longest common prefix
    local commonPrefix=$(printf "%s\n" "${_lower[@]}" | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}')
    # but not numbers that may happen to be in common
    # so that 11 and 12 don't become 1 and 2
    commonPrefix=$(echo "$commonPrefix" | sed 's/[0-9]\+$//')
    # nor roman numerals counting I, II, III, IV (lower-cased here)
    if [[ $commonPrefix == *" i" ]]; then
        commonPrefix=${commonPrefix:0:-1}
    fi

    # find the longest common suffix, by twice inverting
    local commonSuffix=$(printf "%s\n" "${_lower[@]}" | rev | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}' | rev)

    # leave closing brackets if brackets were opened in name
    # but not if opening was also trimmed in prefix
    if [[ $commonSuffix == ")"*  && ! $commonPrefix == *"("* ]]; then
        commonSuffix=${commonSuffix:1}
    fi

    # remove prefix and suffix
    # but not by mangling inside words, meaning
    # prefixes and suffixes that are only letters without spaces are
    # kept (e.g. last, lost, list and not ast, ost, ist)
    # removal is done by length so the original (mixed-case) characters go too
    local _i _len
    if [[ $commonPrefix =~ [^a-zA-Z] ]]; then
        for _i in "${!_items[@]}"; do
            _items[_i]="${_items[_i]:${#commonPrefix}}"
        done
    fi
    if [[ $commonSuffix =~ [^a-zA-Z] ]]; then
        for _i in "${!_items[@]}"; do
            _len=$(( ${#_items[_i]} - ${#commonSuffix} ))
            _items[_i]="${_items[_i]:0:_len}"
        done
    fi

    # export to output array
    __dst=("${_items[@]}")
}
