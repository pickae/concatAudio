#!/bin/bash
set -euo pipefail

credits="David Ernst"

usage="Usage:
    $0 <inputDir> <outputDir>
    
    Default behavior
    ----------------
    requires per desired output file one subfolder in input
    each subfolder respectively needs to have only mp3, opus or aac audio
    those can be in various recursive folders
    the naming of those files and subfolders should reflect the desired order

    Chapters
    --------
    priority: retrieve chapters from cue file
    fallback: concat files and build chapters from individual files

    Thumbnail
    ---------
    embed cover from image file(s) in input folder
    fallback: extract from pdf documents instead
    fallback: extract from audio files themselves

    Dependencies
    ------------
    ffmpeg, mkvtoolnix, pdftoppm, imagemagick, wc, mutagen"

OPTIND=1

# TODO
# depend a lot less on temp files and do much more in RAM
# for name files, and also the chapter and thumbnail files

while getopts ":h" opt; do
    case "$opt" in
    h)
        printf "%s\n\n%s\n" "$credits" "$usage"
        exit 0
        ;;
    *) ;;

    esac
done
shift $((OPTIND - 1))

# global variables
# not exported: these are only read inside this shell and its functions,
# the external tools receive what they need as arguments, not via the environment
scriptDir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
inputDir="$1"
outputDir="$2"
imageSizeLimit=700000
fullHD="1920x1080"
quadHD="2560x1440"
ultra4K="3840x2160"
dpi=300
jpgQualityLevel=80
XARGS() {
	xargs -r0 "$@"
}

# in-memory replacements for the former temporary list files
# these hold what used to be written line by line to text files
INPUT_PATHS=()
OUTPUT_PATHS=()
CONCAT_LIST=()
CHAPTER_LINES=()
RET_PREFIX=""
RET_NAME=""

# concise progress reporting: the noisy tool output is silenced below, so use
# this helper to print meaningful step-by-step updates on stderr instead
log() {
    printf '==> %s\n' "$*" >&2
}


# Validate input
if [ "$#" -lt 2 ]; then
    printf "%s\n\n%s\n" "$credits" "$usage"
    exit 1
fi
if [ ! -d "$inputDir" ]; then
    printf "Directory \"%s\" does not exist.\n\n%s\n" "$inputDir" "$usage"
    exit 1
fi

cleanInputPath() {
    local newName="$1"
    newName=${newName//"_"/ }
    newName=${newName//"'"/}
    newName=${newName//"!"/}
    newName=${newName//"\`"/}

    # remove double spaces and trailing spaces
    newName=$(echo "$newName" | xargs)
    echo "$newName"
}

pretreatInput() {
    # address only known problems in filenames and paths
    # as little interference as possible

    # folders
    # breadth first cleanup, if multiple levels need cleanup
    local maxDepth
    maxDepth=$(find "$inputDir" -type d -printf '%d\n' | sort -rn | head -1)
    local depth
    for (( depth=1; depth<=$maxDepth; depth++ ))
    do
        find "$inputDir" -maxdepth "$depth" -mindepth "$depth" -type d -print |
        while IFS= read folder; do
            local cleanFolder=$(cleanInputPath "$folder")
            if [[ "$folder" != "$cleanFolder" ]]; then
                mv -f "$folder" "$cleanFolder"
            fi
        done
    done

    # relevant audio files
    find "$inputDir" -type f \( -iname '*.opus' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.m4b' -o -iname '*.aac' \) -print |
        while IFS= read file; do
            local fileName=$(cleanInputPath "$file")
            if [[ "$file" != "$fileName" ]]; then
                mv -f "$file" "$fileName"
            fi
        done

    # lower case extensions
    find "$inputDir" -type f -print |
        while IFS= read file; do
            local fileName="${file%.*}"
            local ending="${file##*.}"
            if [[ $(echo "$ending" | awk '/[A-Z]/') ]]; then
                local newName="$fileName"."${ending,,}"
                mv -- "$file" "$newName" || true
            fi
        done

    # extension types
    find "$inputDir" -type f -iname '*.m4b' -print |
        while IFS= read file; do
            mv -f "$file" "${file%.*}.m4a"
        done
    find "$inputDir" -type f -iname '*.m4a' -print |
        while IFS= read file; do
            local outputAAC="${file%.*}.aac"
            if [[ ! -f "$outputAAC" ]]; then
                ffmpeg -nostdin -hide_banner -loglevel error -i "$file" -acodec copy "$outputAAC"
            fi
        done
    find "$inputDir" -type f -iname '*.jpeg' -print |
        while IFS= read file; do
            mv -f "$file" "${file%.*}.jpg"
        done
}

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

cleanNamesCollectively() {
    # TODO : case insensitive

    # operate on in-memory arrays passed by name
    # $1 : name of the input array, $2 : name of the output array
    local -n __src="$1"
    local -n __dst="$2"
    local _items=("${__src[@]}")

    # find the longest common prefix
    local commonPrefix=$(printf "%s\n" "${_items[@]}" | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}')
    # but not numbers that may happen to be in common
    # so that 11 and 12 don't become 1 and 2
    commonPrefix=$(echo "$commonPrefix" | sed 's/[0-9]\+$//')
    # nor roman numerals counting I, II, III, IV
    if [[ $commonPrefix == *" I" ]]; then
        commonPrefix=${commonPrefix:0:-1}
    fi

    # find the longest common suffix, by twice inverting
    local commonSuffix=$(printf "%s\n" "${_items[@]}" | rev | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}' | rev)

    # leave closing brackets if brackets were opened in name
    # but not if opening was also trimmed in prefix
    if [[ $commonSuffix == ")"*  && ! $commonPrefix == *"("* ]]; then
        commonSuffix=${commonSuffix:1}
    fi

    # remove prefix and suffix
    # but not by mangling inside words, meaning
    # prefixes and suffixes that are only letters without spaces are
    # kept (e.g. last, lost, list and not ast, ost, ist)
    if [[ $commonPrefix =~ [^a-zA-Z] ]]; then
        _items=("${_items[@]#"$commonPrefix"}")
    fi
    if [[ $commonSuffix =~ [^a-zA-Z] ]]; then
        _items=("${_items[@]%"$commonSuffix"}")
    fi

    # export to output array
    __dst=("${_items[@]}")
}

nameOutputFiles() {
    # Variables
    local inputDir="$1"
    local dirNumber=($(find "$inputDir" -maxdepth 1 -mindepth 1 -type d -printf x | wc -c))

    # make initial list (kept in memory instead of a path file)
    local dirList
    readarray -t dirList < <(find "$inputDir" -maxdepth 1 -mindepth 1 -type d | sort -V)
    INPUT_PATHS=("${dirList[@]}")

    # first an individual renaming pass to identitfy prefixes
    # loop to build prefix and name lists in memory
    local prefixes=()
    local names=()
    local dir
    for dir in "${dirList[@]}"; do
        dir=$(basename -- "$dir")
        # split prefix number if available, clean the name
        cleanNamesIndividually "$dir"
        prefixes+=("$RET_PREFIX")
        names+=("$RET_NAME")
    done

    # rename collectively to remove common prefixes and suffixes
    # only applicable for multiple input folders
    local cleanNames=()
    if  [[ $dirNumber -gt 1 ]]; then
        cleanNamesCollectively names cleanNames
    else
        cleanNames=("${names[@]}")
    fi

    # if no prefixes were removed individually, they could still be there
    # because blocked by common text in front, which is now gone
    local cleanerNames=()
    if [[ -z "${prefixes[0]:-}" ]]; then
        prefixes=()
        local cleanName
        for cleanName in "${cleanNames[@]}"; do
            cleanNamesIndividually "$cleanName"
            prefixes+=("$RET_PREFIX")
            cleanerNames+=("$RET_NAME")
        done
    else
        cleanerNames=("${cleanNames[@]}")
    fi

    # concat clean paths
    OUTPUT_PATHS=()
    local outputFileNumber=1
    local name
    for name in "${cleanerNames[@]}"; do
        local prefix="${prefixes[outputFileNumber-1]}"

        # folders with dots in the name would not make acceptable filenames
        name=${name//"."/}

        # put prefix only if applicable
        # so that there is no leading space without prefix
        local path
        if [[ ${#prefix} > 0 ]]; then
            path="$outputDir/$prefix $name"
        else
            path="$outputDir/$name"
        fi
        path=${path//"//"/"/"}

        OUTPUT_PATHS+=("$path")

        ((outputFileNumber = outputFileNumber + 1))
    done
}

concatM4a() {
    cd "$1"

    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local outputFile="$fileBaseName.m4b"
    # intermediary concat file kept in RAM, not on the SSD
    local tempAAC="$ramDir/$(basename -- "$fileBaseName").aac"
    local fileList=$(find "$inputFolder" -maxdepth 1 -type f -iname '*.aac')

    # concat all aac files
    if [[ ${#fileList} -ge 1 ]]; then
        # TODO : search recursively and make fileList across subsubfolders
        # TODO : natural sorting, e.g. 11 after 2

        cat *.aac >>"$tempAAC"
        ffmpeg -nostdin -hide_banner -loglevel error -i "$tempAAC" -acodec copy -bsf:a aac_adtstoasc "$outputFile"
        rm -rf "$tempAAC"
        find "$inputFolder" -type f -name '*.aac' -delete
    fi
}

concatMp3() {
    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local outputFile="$fileBaseName.mp3"
    local fileList=$(find "$inputFolder" -type f -iname '*.mp3' -exec echo "file '{}'" \;)

    # concat all mp3 files
    if [[ ${#fileList} -ge 1 ]]; then

        # natural sorting, e.g. 11 after 2
        fileList=$(echo "$fileList" | sort -V)

        # keep the concat list in memory (CONCAT_LIST) instead of a list file
        readarray -t CONCAT_LIST <<< "$fileList"

        # feed the list to ffmpeg via process substitution (no temp file)
        ffmpeg -nostdin -hide_banner -loglevel error -safe 0 -f concat -i <(printf "%s\n" "${CONCAT_LIST[@]}") -codec copy "$outputFile"
    fi
}

concatOpus() {
    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local outputFile="$fileBaseName.opus"
    local fileList=$(find "$inputFolder" -type f -iname '*.opus' -exec echo "file '{}'" \;)

    # concat all opus files
    if [[ ${#fileList} -ge 1 ]]; then

        # natural sorting, e.g. 11 after 2
        fileList=$(echo "$fileList" | sort -V)

        # keep the concat list in memory (CONCAT_LIST) instead of a list file
        readarray -t CONCAT_LIST <<< "$fileList"

        # feed the list to ffmpeg via process substitution (no temp file)
        ffmpeg -nostdin -hide_banner -loglevel error -safe 0 -f concat -i <(printf "%s\n" "${CONCAT_LIST[@]}") -codec copy "$outputFile"
    fi
}

timeRow() {
    # outputs row like
    # CHAPTER01=00:00:00.000

    # Variables
    local chapterNumber="$1"
    local paddedChapterNumber
    printf -v paddedChapterNumber "%02d" $chapterNumber
    local length=$2

    # format from milliseconds to string
    local hours=$((length / 3600000))
    printf -v hours "%02d" $hours
    local minutes=$((length % 3600000 / 60000))
    printf -v minutes "%02d" $minutes
    local seconds=$((length % 3600000 % 60000 / 1000))
    printf -v seconds "%02d" $seconds
    local milliseconds=$((length % 3600000 % 60000 % 1000))
    printf -v milliseconds "%03d" $milliseconds
    local timeStamp="$hours:$minutes:$seconds.$milliseconds"

    # append to the in-memory chapter list
    CHAPTER_LINES+=("CHAPTER$paddedChapterNumber=$timeStamp")
}

nameRow() {
    # outputs row like
    # CHAPTER01NAME=Intro

    # Variables
    local chapterNumber="$1"
    local paddedChapterNumber
    printf -v paddedChapterNumber "%02d" $chapterNumber
    local chapterName="$2"

    # append to the in-memory chapter list
    CHAPTER_LINES+=("CHAPTER${paddedChapterNumber}NAME=$chapterName")
}

chaptersFromFiles() {
    # takes as input the in-memory concat list (CONCAT_LIST)
    # same list ffmpeg used to concat the files
    # which makes sure the order of the chapters always corresponds to the concatenation

    # builds the chapters in memory (CHAPTER_LINES) in ogm format
    # https://github.com/fireattack/chapter_converter
    # CHAPTER01=00:00:00.000
    # CHAPTER01NAME=Intro
    # CHAPTER02=00:02:30.000
    # CHAPTER02NAME=Main Body
    # CHAPTER03=00:07:34.000
    # CHAPTER03NAME=Outro

    # start with a fresh chapter list
    CHAPTER_LINES=()

    # First loop to make name lists in memory
    local names=()
    local tempPrefixes=()
    local file
    for file in "${CONCAT_LIST[@]}"; do
        # format
        file=${file//"file "/}
        file=$(echo "$file" | tr -d "'")
        file=$(basename -- "$file")

        # collect name and prefix
        cleanNamesIndividually "${file%.*}"
        tempPrefixes+=("$RET_PREFIX")
        names+=("$RET_NAME")
    done

    # Clean chapter names as seen collectively
    # Anything that is leading or trailing all names is removed
    local cleanNames=()
    cleanNamesCollectively names cleanNames
    # prefixes could also be all the same number
    # in which case they should be seen as if no prefixes were removed
    local prefixes=()
    cleanNamesCollectively tempPrefixes prefixes

    # Second loop to write the chapter
    # cannot be done in one loop because one chapter's name can depend on the other chapters

    # initialize file loop
    local chapterNumber=1
    # initialize cumulative length
    local accumulatedLength=0
    # loop scratch variables, kept local to this function
    local cleanName prefix tempName chapterName fileLength
    for file in "${CONCAT_LIST[@]}"; do
        # Variables
        file=${file//"file "/}
        file=$(echo "$file" | tr -d "'")
        cleanName="${cleanNames[chapterNumber-1]}"
        prefix="${prefixes[chapterNumber-1]}"

        # if no prefixes were removed individually
        # or if the "prefixes" were all the same number
        # the prefixes could still be there
        # because blocked by common text in front, which is now gone
        # remove them, but only if something remains of the name
        if [[ -z "$prefix" ]]; then
            cleanNamesIndividually "$cleanName"
            tempName="$RET_NAME"
            if [[ ! -z "$tempName" ]]; then
                cleanName="$tempName"
            fi
        fi

        # prefer to print name without number prefix
        # except for dates
        # or print only number if nothing else exists
        if [[ -z "$cleanName" ]]; then
            chapterName="$prefix"
        elif [[ ${#prefix} -ge 8 ]]; then
            chapterName="$prefix $cleanName"
        else
            chapterName="$cleanName"
        fi

        # write rows
        timeRow "$chapterNumber" "$accumulatedLength"
        nameRow "$chapterNumber" "$chapterName"

        # increment loop
        fileLength=$(ffprobe -i "$file" -show_format -v quiet | sed -n 's/duration=//p' | xargs printf %.3f)
        fileLength=${fileLength//"."/}
        fileLength=$(sed -e 's/^"//' -e 's/"$//' <<<"$fileLength")
        # for sub second files
        fileLength=$(echo $fileLength | sed 's/^0*//')

        ((accumulatedLength = accumulatedLength + fileLength))
        ((chapterNumber = chapterNumber + 1))
    done
}

timeFromCueString() {
    # converts the cue sheet time format to flat milliseconds
    # so that those can be converted back to the slightly different chapter file time format

    # the 10 digits input string is only good for >1000 minute long files
    # everything else needs to be trimmed
    local formattedTime=$(echo "$1" | xargs echo -n)
    formattedTime=$(echo $formattedTime|tr -d '\r')
    formattedTime=${formattedTime#* }

    # split into components and compute
    if [[ "$formattedTime" == "00:00:00" || "$formattedTime" == "0:00:00" || "$formattedTime" == "0:0:00" ]]; then
        local length=0
    else
        local minutes=${formattedTime%:*}
        minutes=${minutes%:*}
        minutes=$(echo $minutes | sed 's/^0*//')
        local seconds=${formattedTime#*:}
        seconds=${seconds%:*}
        seconds=$(echo $seconds | sed 's/^0*//')
        local centiseconds=${formattedTime#*:}
        centiseconds=${centiseconds#*:}
        centiseconds=$(echo $centiseconds | sed 's/^0*//')

        # convert to flat milliseconds
        local length=$((minutes * 60 * 1000 + seconds * 1000 + centiseconds * 10))       
    fi

    # return
    echo "$length"
}

chaptersFromCue() {
    # parses a cue file to retrieve chapters
    # https://en.wikipedia.org/wiki/Cue_sheet_(computing)
    # https://kodi.wiki/view/Cue_sheets

    local cueFile="$1"

    # start with a fresh chapter list (kept in memory)
    CHAPTER_LINES=()

    # initialize row counter
    local rowCounter=1
    # initialize chapter counter
    local chapterCounter=1
    # initialize start-time
    local startTime=0
    # initialization parameter to ignore TITLE of file header
    local start=0
    # initialize chapter title
    local title="emptyFile"
    local line

    # Read the input cue file
    # redirect instead of a pipe so the in-memory chapter list survives the loop
    while read line; do

        # initialize
        if [[ "$line" == *"TRACK"* ]]; then
            start=1
        fi

        # parse line for title information
        if [[ "$line" == *"TITLE"* && "$start" -ge 1 ]]; then
            # set chapter name
            local separator='TITLE '
            case $line in
                (*"$separator"*)
                    local header=${line%%"$separator"*}
                    title=${line#*"$separator"}
                    ;;
                (*)
                    local header=$separator
                    title=
                    ;;
            esac
        
        # parse line for time information
        elif [[ "$line" == *"INDEX 01"* && "$start" -ge 1 ]]; then
            # extract formatted time string and convert to millisecond
            local formattedTime=${line: -10}
            startTime=$(timeFromCueString "$formattedTime")
        fi

        # Write a chapter not for each row in the cue, but only once per chapter
        # - write only when start-time and name of a chapter are assembled
        # - be able to write first chapter with time 0
        # - execute only when first chapter is reached, ignore header title
        if [[ (("$startTime" != "0" && "$title" != *"emptyFile"*) ||
            ("$title" != *"emptyFile"* && "$chapterCounter" -le 1)) &&
            "$start" -ge 1 ]]; then

            cleanNamesIndividually "$title"
            title="$RET_NAME"

            # print
            timeRow "$chapterCounter" "$startTime"
            nameRow "$chapterCounter" "$title"

            # reinitialize chapter info
            startTime=0
            title="emptyFile"

            # increment chapter
            chapterCounter=$((chapterCounter + 1))
        fi

        # increment row
        rowCounter=$((rowCounter + 1))
    done < "$cueFile"
}

embedChapters() {

    # Variables
    local chapterFile="$1"
    local opusFile="${chapterFile%.*}.opus"
    local mp3File="${chapterFile%.*}.mp3"
    local m4bFile="${chapterFile%.*}.m4b"
    # intermediary mka detour kept in RAM, not on the SSD
    local mkaFile="$ramDir/$(basename -- "${chapterFile%.*}").mka"
    local title=$(basename -- "$1")
    title="${title%.*}"

    # pick whichever of the audio files actually exists (only one should);
    # every step below then acts on that single file, instead of repeating the
    # same logic once per possible extension
    local audioFile=""
    if [[ -f "$opusFile" ]]; then
        audioFile="$opusFile"
    elif [[ -f "$mp3File" ]]; then
        audioFile="$mp3File"
    elif [[ -f "$m4bFile" ]]; then
        audioFile="$m4bFile"
    fi

    # detour over mka for embedding chapters
    # but only if there is more than one chapter
    # TODO : directly with mutagen
    if [[ ${#CHAPTER_LINES[@]} -ge 4 ]]; then
        # mkvmerge needs a seekable chapters file, so serialize the in-memory
        # list to a RAM-backed temporary file (removed right after the call)
        local chapterTemp
        chapterTemp=$(mktemp --tmpdir=/dev/shm 2>/dev/null || mktemp)
        printf "%s\n" "${CHAPTER_LINES[@]}" >"$chapterTemp"
        if [[ -n "$audioFile" ]]; then
            mkvmerge --quiet "$audioFile" --chapters "$chapterTemp" -o "$mkaFile" || true
        fi
        rm -rf "$chapterTemp"
    elif [[ -n "$audioFile" ]]; then
        mkvmerge --quiet "$audioFile" -o "$mkaFile" || true
    fi

    # set title
    mkvpropedit --quiet "$mkaFile" --edit info --set "title=$title" --edit track:1 --set "name=$title"

    # re-extract audio file from mka, now with chapters
    if [[ -n "$audioFile" ]]; then
        # the m4b is overwritten in place, so clear it before re-muxing
        if [[ "$audioFile" == "$m4bFile" ]]; then
            rm -rf "$m4bFile"
        fi
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$mkaFile" -codec copy "$audioFile"
    fi
    rm -rf "$mkaFile"
}

chooseThumbnail() {
    
    # Variables
    local inputPath="$1"
    local fileName="$2"

    # shared image-extension predicate group used by the refinement passes
    local imgs=( '(' -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' ')' )

    # update the chosen thumbnail whenever the given find predicates match
    # something; the passes below run in increasing order of priority, so a
    # later match overrides an earlier one
    _pickThumb() {
        local match
        match=$(find "$inputPath" -type f "$@")
        if [[ ${#match} -ge 1 ]]; then
            tempThumb="$match"
        fi
    }

    # first take any image file in folder as potential thumbnail
    local tempThumb
    tempThumb=$(find "$inputPath" -type f -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif')

    # refine choice in increasing order of priority
    _pickThumb -iname '*back*'   -a "${imgs[@]}"
    _pickThumb -iname '*folder*' -a "${imgs[@]}"
    _pickThumb -iname '*inlay*'  -a "${imgs[@]}"
    _pickThumb -iname '*cover*'  -a -not -iname '*back*' -a "${imgs[@]}"
    _pickThumb -iname '*front*'  -a "${imgs[@]}"
    _pickThumb -iname '*cover*'  -a -iname '*front*'     -a "${imgs[@]}"

    # return the highest-priority match
    echo "$tempThumb" | head -1
}

extractThumbnail() {

    # Variables
    local inputPath="$1"
    local fileName="$2"

    # choose pdf to extract from
    local tempPDF=""
    tempPDF=$(find "$inputPath" -type f -iname '*scan*' -a -iname '*.pdf')
    if [[ ! ${#tempPDF} -ge 1 ]]; then
        tempPDF=$(find "$inputPath" -type f -iname '*booklet*' -a -iname '*.pdf')
    fi

    # if a pdf was found, extract first page
    if [[ ${#tempPDF} -ge 1 ]]; then
        local pdfFile=$(echo "${tempPDF}" | head -1)
        pdftoppm "$pdfFile" "$fileName" -jpeg -rx "$dpi" -ry "$dpi" -f 1 -singlefile
    
    else
    # or extract from the audio files, if nothing was found till now
    # see if we have mp3 or opus files, extractions is different
        local sourceOpus=$(find "$inputPath" -type f -iname '*.opus')
        sourceOpus=$(echo "${sourceOpus}" | head -1)
        local sourceMp3=$(find "$inputPath" -type f -iname '*.mp3')
        sourceMp3=$(echo "${sourceMp3}" | head -1)

        # take any opus file, assume they all have the thumbnail embedded
        if [[ ${#sourceOpus} -ge 1 ]]; then
            # detour over mka for extractability, kept in RAM
            local tempFile="$ramDir/${sourceOpus##*/}"
            tempFile="${tempFile%.*}.mka"
            mkvmerge --quiet -o "$tempFile" --no-chapters "$sourceOpus"
            mkvextract --quiet "$tempFile" attachments 1:"$fileName.jpg" || true
            rm -rf "$tempFile"
        # or take any mp3 file, assume they all have the thumbnail embedded
        elif [[ ${#sourceMp3} -ge 1 ]]; then
            ffmpeg -nostdin -hide_banner -loglevel error -i "$sourceMp3" -an -vcodec copy "$fileName.jpg" || true
        # TODO m4a
        fi
    fi
}

embedThumbnail() {

    # Variables
    local inputPath="$1"
    local fileName=${2%/}
    local opusFile="$fileName.opus"
    local mp3File="$fileName.mp3"
    local m4bFile="$fileName.m4b"
    # RAM-backed scratch base for the intermediary thumbnail and audio temp files
    local ramBase="$ramDir/$(basename -- "$fileName")"
    local m4bTempFile="$ramBase.temp.m4b"

    # choose thumbnail from image file
    local thumbFile=$(chooseThumbnail "$inputPath" "$fileName")

    # or extract from pdf file or audio file themselves, if nothing was found till now
    if [[ ! -f "$thumbFile" ]]; then
        extractThumbnail "$inputPath" "$ramBase"
        local thumbFile="$ramBase.jpg"
    fi

    # rename just in case it's already in that folder (if extracted from audio file)
    # because convert cannot overwrite in place
    local outputThumb="$ramDir/${thumbFile##*/}"
    outputThumb="${outputThumb%.*}.output.jpg"
    outputThumb=${outputThumb//"//"/"/"}

    # convert if too large or wrong format
    if [[ -f "$thumbFile" ]]; then
        local fileSize=$(stat --format=%s "$thumbFile")
        if [[ "$fileSize" -ge "$imageSizeLimit" || "${thumbFile: -4}" != ".jpg"  ]]; then
            convert -quiet "$thumbFile" -quality "$jpgQualityLevel" -resize "$quadHD"\> "$outputThumb"
        else
            cp "$thumbFile" "$outputThumb"
        fi
    fi

    # embed thumbnail if applicable
    if [[ -f "$outputThumb" ]]; then
        if [[ -f "$opusFile" ]]; then
            python3 "$scriptDir/mutagenScript.py" "$opusFile" "$outputThumb"
            rm -rf "$outputThumb"
        elif [[ -f "$mp3File" ]]; then
            local mp3TempFile="$ramBase.temp.mp3"
            ffmpeg -nostdin -hide_banner -loglevel error -i "$mp3File" -i "$outputThumb" \
                -c copy -map 0 -map 1 "$mp3TempFile"
            rm -rf "$mp3File"
            rm -rf "$outputThumb"
            mv -f "$mp3TempFile" "$mp3File"
        elif [[ -f "$m4bFile" ]]; then
            ffmpeg -nostdin -hide_banner -loglevel error -i "$m4bFile" -i "$outputThumb" \
                -c copy -disposition:v:0 attached_pic "$m4bTempFile"
            rm -rf "$m4bFile"
            rm -rf "$outputThumb"
            mv -f "$m4bTempFile" "$m4bFile"
        fi
    fi
}

mainFunction() {
    local inputDir="$1"
    local outputDir="$2"
    
    cd "$inputDir"

    # minimal pretreatment of the actual inputfolder
    log "Pretreating input folders in \"$inputDir\""
    local d
    for d in */; do
        [ -L "${d%/}" ] && continue
        pretreatInput "$d"
    done

    # determine output filenames (populates the in-memory INPUT_PATHS and OUTPUT_PATHS)
    log "Determining output file names"
    nameOutputFiles "$inputDir"

    # main loop to make one output file per input subfolder
    cd "$inputDir"
    local i
    # loop variables, kept local to this function
    local inputPath outputPath chapterFile cueFiles cueFile concatDone audioFiles chaptersNeeded
    local mp3Files opusFiles m4aFiles
    for (( i=0; i<${#INPUT_PATHS[@]}; i++ )); do
        inputPath="${INPUT_PATHS[i]}"
        outputPath="${OUTPUT_PATHS[i]}"
        chapterFile="${outputPath%/}.ch"

        log "[$((i + 1))/${#INPUT_PATHS[@]}] Processing \"$(basename -- "${outputPath%/}")\""

        # start each subfolder with fresh in-memory lists
        CONCAT_LIST=()
        CHAPTER_LINES=()

        mp3Files=($(find "$inputPath" -type f -name "*.mp3" -printf x | wc -c))
        opusFiles=($(find "$inputPath" -type f -name "*.opus" -printf x | wc -c))
        m4aFiles=($(find "$inputPath" -type f -name "*.aac" -printf x | wc -c))
        cueFiles=$(find "$inputPath" -type f -iname '*.cue')
        concatDone=0

        # concat
        if  ([[ $mp3Files -gt 0 && $opusFiles -eq 0 && $m4aFiles -eq 0 ]]); then
            log "    Concatenating $mp3Files MP3 file(s)"
            concatMp3 "$inputPath" "$outputPath"
            concatDone=1
        elif ([[ $mp3Files -eq 0 && $opusFiles -gt 0 && $m4aFiles -eq 0 ]]); then
            log "    Concatenating $opusFiles Opus file(s)"
            concatOpus "$inputPath" "$outputPath"
            concatDone=1
        elif ([[ $mp3Files -eq 0 && $opusFiles -eq 0 && $m4aFiles -gt 0 ]]); then
            log "    Concatenating $m4aFiles AAC file(s)"
            concatM4a "$inputPath" "$outputPath"
            concatDone=1
        fi

        if [[ $concatDone == 1 ]]; then
            
            ((audioFiles = $mp3Files + $opusFiles + $m4aFiles))

            # one of two ways to retrieve chapters
            # cue sheets have priority if they exist and are needed because music isn't yet split
            chaptersNeeded=0
            if [[ ${#cueFiles} -ge 1 && $audioFiles == 1 ]]; then
                # if there is only one audio file and a cue sheet
                # take the chapters from any cue sheet in the folder
                # this means CD1 CD2 types of input need separate folders per CD
                cueFile=$(echo "${cueFiles}" | head -1)
                log "    Reading chapters from cue sheet"
                chaptersFromCue "$cueFile"
                chaptersNeeded=1
            elif [[ $audioFiles -ge 2 ]]; then
                # else the audio files are the chapters
                log "    Building chapters from individual files"
                chaptersFromFiles
                chaptersNeeded=1
            fi

            # make pretty
            if [[ $chaptersNeeded == 1 ]]; then
                log "    Embedding chapters"
                embedChapters "$chapterFile"
            fi
            log "    Embedding thumbnail"
            embedThumbnail "$inputPath" "$outputPath"
        fi
    done
}

########
# MAIN #
########

# Prepare Output folder
if [ -d "$outputDir" ]; then 
    find "$outputDir" -type f -name '*.ch' -delete
else
    mkdir -p "$outputDir"
fi

# RAM-backed scratch directory for the bigger intermediary audio and image files
# so they don't put write load on the SSD; only the final output files are
# written to disk. Assumes enough RAM to hold all temporary audio files.
ramDir="/dev/shm/concatAudio.$$"
mkdir -p "$ramDir"
trap 'rm -rf "$ramDir"' EXIT

mainFunction "$inputDir" "$outputDir"

# Cleanup
log "Cleaning up temporary files"
find "$outputDir" -type f -name '*.ls' -delete
find "$outputDir" -type f -name '*.jpg' -delete
find "$outputDir" -type d -empty -delete

log "Done. Output written to \"$outputDir\""