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
export scriptDir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export inputDir="$1"
export outputDir="$2"
export imageSizeLimit=700000
export fullHD="1920x1080"
export quadHD="2560x1440"
export ultra4K="3840x2160"
export dpi=300
export jpgQualityLevel=80
XARGS() {
	xargs -r0 "$@"
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
    maxDepth=$(find "$inputDir" -type d -printf '%d\n' | sort -rn | head -1)
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
                echo "$file"
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
                mv -- "$file" "$newName" | true
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
                ffmpeg -i "$file" -acodec copy "$outputAAC"
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
    local datePattern='([1-2][0-9][0-9][0-9][0-9][0-9][0-9][0-9])'
    local date="${newName:0:8}"
    local dashedNumbersPattern='([0-9][0-9][-][0-9][0-9])'
    local dashedNumbers="${newName:0:5}"
    local fourNumberPattern='([0-9][0-9][0-9][0-9])'
    local fourNumbers="${newName:0:4}"
    local threeNumberPattern='([0-9][0-9][0-9])'
    local threeNumbers="${newName:0:3}"
    local twoNumberPattern='([0-9][0-9])'
    local twoNumbers="${newName:0:2}"
    local twoNumbersBrackets="${newName:1:2}"
    local oneNumberPattern='([0-9])'
    local oneNumber="${newName:0:1}"

    # start checking for the longest numbers
    # work way down, otherwise it mangles the numbers
    if [[ $date =~ $datePattern ]]; then
        newName=${newName:8}
        local prefix="$date"
    elif [[ $dashedNumbers =~ $dashedNumbersPattern ]]; then
        newName=${newName:5}
        local prefix="$dashedNumbers"
    elif [[ $fourNumbers =~ $fourNumberPattern ]]; then
        newName=${newName:4}
        local prefix="$fourNumbers"
    elif [[ $threeNumbers =~ $threeNumberPattern ]]; then
        newName=${newName:3}
        local prefix="$threeNumbers"
    elif [[ $twoNumbers =~ $twoNumberPattern ]]; then
        newName=${newName:2}
        local prefix="$twoNumbers"
    elif [[ $twoNumbersBrackets =~ $twoNumberPattern ]]; then
        newName=${newName:4}
        local prefix="$twoNumbersBrackets"
    elif [[ $oneNumber =~ $oneNumberPattern ]]; then
        newName=${newName:1}
        local prefix="$oneNumber"
    else
        local prefix=""
    fi

    # remove double spaces and trailing spaces and dashes
    newName=$(echo "$newName" | xargs)
    newName=$(echo "$newName" | sed 's/[-]*$//g')
    newName=$(echo "$newName" | sed 's/[.]*$//g')
    newName=$(echo "$newName" | sed 's/[/]*$//g')
    newName=$(echo "$newName" | sed 's/[_]*$//g')
    newName=$(echo "$newName" | xargs)

    # depending on how the function is called, it either only returns the name
    # or writes the name and prefix to files for further processing
    local writeFiles="${2:-false}"
    if [[ "$writeFiles" = false ]]; then
        echo "$newName"
    else
        echo "$prefix" >>"$2"
        echo "$newName" >>"$3"
    fi
}

cleanNamesCollectively() {
    # TODO : case insensitive
    
    # assign fileread to array variable
    local names
    readarray -t names < "$1"
    local cleanNames="$2"

    # find the longest common prefix
    local commonPrefix=$(printf "%s\n" "${names[@]}" | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}')
    # but not numbers that may happen to be in common
    # so that 11 and 12 don't become 1 and 2
    commonPrefix=$(echo "$commonPrefix" | sed 's/[0-9]\+$//')
    # nor roman numerals counting I, II, III, IV
    if [[ $commonPrefix == *" I" ]]; then
        commonPrefix=${commonPrefix:0:-1}
    fi

    # find the longest common suffix, by twice inverting
    local commonSuffix=$(printf "%s\n" "${names[@]}" | rev | sed -e '$!{N;s/^\(.*\).*\n\1.*$/\1\n\1/;D;}' | rev)

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
        names=("${names[@]#"$commonPrefix"}")
    fi
    if [[ $commonSuffix =~ [^a-zA-Z] ]]; then
        names=("${names[@]%"$commonSuffix"}")
    fi

    # export to file
    printf "%s\n" "${names[@]}" > "$cleanNames"
}

nameOutputFiles() {
    # Variables
    local inputDir="$1"
    local dirNumber=($(find "$inputDir" -maxdepth 1 -mindepth 1 -type d -printf x | wc -c))
    local pathFile="$2"
    local cleanPathFile="$3"
    local nameFile="$outputDir/folders.name"
    local prefixFile="$outputDir/folders.prefix"
    local cleanNameFile="$outputDir/folders.cleanname"
    local cleanerNameFile="$outputDir/folders.cleanername"

    # make initial list
    local dirList=$(find "$inputDir" -maxdepth 1 -mindepth 1 -type d)
    dirList=$(echo "$dirList" | sort -V)
    echo "$dirList" >"$pathFile"
    
    # first an individual renaming pass to identitfy prefixes
    # loop to create prefix and name files
    cat "$pathFile" | while read dir; do
        dir=$(basename -- "$dir")
        # split prefix number if available, clean the name
        cleanNamesIndividually "$dir" "$prefixFile" "$nameFile"
    done

    # rename collectively to remove common prefixes and suffixes
    # only applicable for multiple input folders
    if  [[ $dirNumber -gt 1 ]]; then
        cleanNamesCollectively "$nameFile" "$cleanNameFile"
    else
        cp "$nameFile" "$cleanNameFile"
    fi

    # if no prefixes were removed individually, they could still be there
    # because blocked by common text in front, which is now gone
    local prefix=$(cat "$prefixFile" | head -"1" | tail -1)
    if [[ -z "$prefix" ]]; then
        rm -rf "$prefixFile"
        cat "$cleanNameFile" | while read cleanName; do
            cleanNamesIndividually "$cleanName" "$prefixFile" "$cleanerNameFile"
        done
    else
        cp "$cleanNameFile" "$cleanerNameFile"
    fi

    # concat clean paths
    local outputFileNumber=1
    cat "$cleanerNameFile" | while read name; do
        local prefix=$(cat "$prefixFile" | head -"$outputFileNumber" | tail -1)

        # folders with dots in the name would not make acceptable filenames
        name=${name//"."/}

        # put prefix only if applicable
        # so that there is no leading space without prefix
        if [[ ${#prefix} > 0 ]]; then
            local path="$outputDir/$prefix $name"
        else
            local path="$outputDir/$name"
        fi
        path=${path//"//"/"/"}

        echo "$path" >>"$cleanPathFile"

        ((outputFileNumber = outputFileNumber + 1))
    done

    # cleanup
    rm -rf "$nameFile"
    rm -rf "$cleanNameFile"
    rm -rf "$cleanerNameFile"
    rm -rf "$prefixFile"
}

concatM4a() {
    cd "$1"

    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local listFile="$3"
    local outputFile="$fileBaseName.m4b"
    local tempAAC="$fileBaseName.aac"
    local fileList=$(find "$inputFolder" -maxdepth 1 -type f -iname '*.aac')

    # concat all aac files
    if [[ ${#fileList} -ge 1 ]]; then
        # TODO : search recursively and make fileList across subsubfolders
        # TODO : natural sorting, e.g. 11 after 2

        local tempAAC
        cat *.aac >>"$tempAAC"
        ffmpeg -i "$tempAAC" -acodec copy -bsf:a aac_adtstoasc "$outputFile"
        rm -rf "$tempAAC"
        find "$inputFolder" -type f -name '*.aac' -delete
    fi
}

concatMp3() {
    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local outputFile="$fileBaseName.mp3"
    local listFile="$3"
    local fileList=$(find "$inputFolder" -type f -iname '*.mp3' -exec echo "file '{}'" \;)

    # concat all mp3 files
    if [[ ${#fileList} -ge 1 ]]; then

        # natural sorting, e.g. 11 after 2
        fileList=$(echo "$fileList" | sort -V)
        echo "$fileList" >"$listFile"
        
        ffmpeg -safe 0 -f concat -i "$listFile" -codec copy "$outputFile"
    fi
}

concatOpus() {
    # Variables
    local inputFolder="$1"
    local fileBaseName="$2"
    local outputFile="$fileBaseName.opus"
    local listFile="$3"
    local fileList=$(find "$inputFolder" -type f -iname '*.opus' -exec echo "file '{}'" \;)

    # concat all opus files
    if [[ ${#fileList} -ge 1 ]]; then

        # natural sorting, e.g. 11 after 2
        fileList=$(echo "$fileList" | sort -V)

        echo "$fileList" >"$listFile"
        ffmpeg -safe 0 -f concat -i "$listFile" -codec copy "$outputFile"
    fi
}

timeRow() {
    # outputs row like
    # CHAPTER01=00:00:00.000

    # Variables
    local outPutFile="$1"
    local chapterNumber="$2"
    printf -v paddedChapterNumber "%02d" $chapterNumber
    length=$3

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

    # print
    echo -n "CHAPTER$paddedChapterNumber=" >>"$outPutFile"
    echo "$timeStamp" >>"$outPutFile"
}

nameRow() {
    # outputs row like
    # CHAPTER01NAME=Intro

    # Variables
    local outPutFile="$1"
    local chapterNumber="$2"
    printf -v paddedChapterNumber "%02d" $chapterNumber
    local chapterName="$3"

    # print
    echo -n "CHAPTER$paddedChapterNumber" >>"$outPutFile"
    echo -n "NAME=" >>"$outPutFile"
    echo "$chapterName" >>"$outPutFile"
}

chaptersFromFiles() {
    # takes as input file list
    # same file as ffmpeg used to concat the files
    # which makes sure the order of the chapters always corresponds to the concatenation
    
    # outputs chapter files in ogm format
    # https://github.com/fireattack/chapter_converter
    # CHAPTER01=00:00:00.000
    # CHAPTER01NAME=Intro
    # CHAPTER02=00:02:30.000
    # CHAPTER02NAME=Main Body
    # CHAPTER03=00:07:34.000
    # CHAPTER03NAME=Outro

    # Variables
    local listFile="$1"
    local tempPrefixFile="${listFile%.*}.temp.prefix"
    local nameFile="${listFile%.*}.name"
    local prefixFile="${listFile%.*}.prefix"
    local cleanNameFile="${listFile%.*}.cleanname"
    local outputFile="$2"

    # First loop to make name files
    cat "$listFile" | while read file; do
        # format
        file=${file//"file "/}
        file=$(echo "$file" | tr -d "'")
        file=$(basename -- "$file")

        # write rows
        cleanNamesIndividually "${file%.*}" "$tempPrefixFile" "$nameFile"
    done

    # Clean chapter names as seen collectively
    # Anything that is leading or trailing all names is removed
    cleanNamesCollectively "$nameFile" "$cleanNameFile"
    # prefixes could also be all the same number
    # in which case they should be seen as if no prefixes were removed
    cleanNamesCollectively "$tempPrefixFile" "$prefixFile"

    # Second loop to write the chapter
    # cannot be done in one loop because one chapter's name can depend on the other chapters

    # initialize file loop
    local chapterNumber=1
    # initialize cumulative length
    local accumulatedLength=0
    cat "$listFile" | while read file; do
        # Variables
        file=${file//"file "/}
        file=$(echo "$file" | tr -d "'")
        cleanName=$(cat "$cleanNameFile" | head -"$chapterNumber" | tail -1)
        prefix=$(cat "$prefixFile" | head -"$chapterNumber" | tail -1)

        # if no prefixes were removed individually
        # or if the "prefixes" were all the same number
        # the prefixes could still be there
        # because blocked by common text in front, which is now gone
        # remove them, but only if something remains of the name
        if [[ -z "$prefix" ]]; then
            tempName=$(cleanNamesIndividually "$cleanName")
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
        timeRow "$outputFile" "$chapterNumber" "$accumulatedLength"
        nameRow "$outputFile" "$chapterNumber" "$chapterName"

        # increment loop
        fileLength=$(ffprobe -i "$file" -show_format -v quiet | sed -n 's/duration=//p' | xargs printf %.3f)
        fileLength=${fileLength//"."/}
        fileLength=$(sed -e 's/^"//' -e 's/"$//' <<<"$fileLength")
        # for sub second files
        fileLength=$(echo $fileLength | sed 's/^0*//')

        ((accumulatedLength = accumulatedLength + fileLength))
        ((chapterNumber = chapterNumber + 1))
    done

    # cleanup
    rm -rf "$prefixFile"
    rm -rf "$tempPrefixFile"
    rm -rf "$nameFile"
    rm -rf "$cleanNameFile"
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

    cueFile="$1"
    chapterFile="$2"

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

    # Read the input cue file
    cat "$cueFile" | while read line; do

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

            title=$(cleanNamesIndividually "$title")

            # print
            timeRow "$chapterFile" "$chapterCounter" "$startTime"
            nameRow "$chapterFile" "$chapterCounter" "$title"

            # reinitialize chapter info
            startTime=0
            title="emptyFile"

            # increment chapter
            chapterCounter=$((chapterCounter + 1))
        fi

        # increment row
        rowCounter=$((rowCounter + 1))
    done
}

embedChapters() {

    # Variables
    local chapterFile="$1"
    local opusFile="${chapterFile%.*}.opus"
    local mp3File="${chapterFile%.*}.mp3"
    local m4bFile="${chapterFile%.*}.m4b"
    local mkaFile="${chapterFile%.*}.mka"
    local title=$(basename -- "$1")
    title="${title%.*}"

    # detour over mka for embedding chapters
    # but only if there is more than one chapter
    # TODO : directly with mutagen
    if [[ $(wc -l <"$chapterFile") -ge 4 ]]; then
        if [[ -f "$opusFile" ]]; then
            mkvmerge "$opusFile" --chapters "$chapterFile" -o "$mkaFile" || true
        elif [[ -f "$mp3File" ]]; then
            mkvmerge "$mp3File" --chapters "$chapterFile" -o "$mkaFile" || true
        elif [[ -f "$m4bFile" ]]; then
            mkvmerge "$m4bFile" --chapters "$chapterFile" -o "$mkaFile" || true
        fi
    else
        if [[ -f "$opusFile" ]]; then
            mkvmerge "$opusFile" -o "$mkaFile" || true
        elif [[ -f "$mp3File" ]]; then
            mkvmerge "$mp3File" -o "$mkaFile" || true
        elif [[ -f "$m4bFile" ]]; then
            mkvmerge "$m4bFile" -o "$mkaFile" || true
        fi
    fi

    # set title
    mkvpropedit "$mkaFile" --edit info --set "title=$title" --edit track:1 --set "name=$title"

    # re-extract audio file from mka, now with chapters
    if [[ -f "$opusFile" ]]; then
        ffmpeg -y -i "$mkaFile" -codec copy "$opusFile"
    elif [[ -f "$mp3File" ]]; then
        ffmpeg -y -i "$mkaFile" -codec copy "$mp3File"
    elif [[ -f "$m4bFile" ]]; then
        rm -rf "$m4bFile"
        ffmpeg -y -i "$mkaFile" -codec copy "$m4bFile"
    fi
    rm -rf "$mkaFile"
}

chooseThumbnail() {
    
    # Variables
    local inputPath="$1"
    local fileName="$2"

    # first take any file in folder as potential thumbnail
    local tempThumb=$(find "$inputPath" -type f -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif')

    # refine choice in increasing order of priority
    local tempFile=$(find "$inputPath" -type f -iname '*back*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempFile=$(find "$inputPath" -type f -iname '*folder*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempFile=$(find "$inputPath" -type f -iname '*inlay*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempFile=$(find "$inputPath" -type f -iname '*cover*' -a -not -iname '*back*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempFile=$(find "$inputPath" -type f -iname '*front*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempFile=$(find "$inputPath" -type f -iname '*cover*' -a -iname '*front*' \
        -a \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.avif' \))
    if [[ ${#tempFile} -ge 1 ]]; then
        tempThumb="$tempFile"
    fi
    tempThumb=$(echo "${tempThumb}" | head -1)

    # return
    echo "$tempThumb"
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
            # detour over mka for extractability
            local tempFile="$outputDir/${sourceOpus##*/}"
            tempFile="${tempFile%.*}.mka"
            mkvmerge "$sourceOpus" -o "$tempFile"
            mkvextract "$tempFile" attachments 1:"$fileName.jpg" || true
            rm -rf "$tempFile"
        # or take any mp3 file, assume they all have the thumbnail embedded
        elif [[ ${#sourceMp3} -ge 1 ]]; then
            ffmpeg -i "$sourceMp3" -an -vcodec copy "$fileName.jpg" || true
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
    local m4bTempFile="$fileName.temp.m4b"

    # choose thumbnail from image or pdf files in input folder
    local thumbFile=$(chooseThumbnail "$inputPath" "$fileName")

    # or extract from audio file themselves, if nothing was found till now
    if [[ ! -f "$thumbFile" ]]; then
        extractThumbnail "$inputPath" "$fileName"
        local thumbFile="$fileName.jpg"
    fi

    # rename just in case it's already in that folder (if extracted from audio file)
    # because convert cannot overwrite in place
    local outputThumb="$outputDir/${thumbFile##*/}"
    outputThumb="${outputThumb%.*}.output.jpg"
    outputThumb=${outputThumb//"//"/"/"}

    # convert if too large or wrong format
    if [[ -f "$thumbFile" ]]; then
        local fileSize=$(stat --format=%s "$thumbFile")
        if [[ "$fileSize" -ge "$imageSizeLimit" || "${thumbFile: -4}" != ".jpg"  ]]; then
            convert "$thumbFile" -quality "$jpgQualityLevel" -resize "$quadHD"\> "$outputThumb"
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
            local mp3TempFile="${mp3File%.*}.temp.mp3"
            ffmpeg -i "$mp3File" -i "$outputThumb" \
                -c copy -map 0 -map 1 "$mp3TempFile"
            rm -rf "$mp3File"
            rm -rf "$outputThumb"
            mv -f "$mp3TempFile" "$mp3File"
        elif [[ -f "$m4bFile" ]]; then
            ffmpeg -i "$m4bFile" -i "$outputThumb" \
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
    for d in */; do
        [ -L "${d%/}" ] && continue
        pretreatInput "$d"
    done

    # determine output filenames
    local inputPathsFile="$outputDir/input.path"
    local outputPathsFile="$outputDir/output.path"
    nameOutputFiles "$inputDir" "$inputPathsFile" "$outputPathsFile"

    # main loop to make one output file per input subfolder
    cd "$inputDir"
    outputFileNumber=1
    cat "$inputPathsFile" | while read inputPath; do
        # TODO : why is it needed to overwrite the inputPath variable again?
        inputPath=$(cat "$inputPathsFile" | head -"$outputFileNumber" | tail -1)
        outputPath=$(cat "$outputPathsFile" | head -"$outputFileNumber" | tail -1)
        listFile="${outputPath%/}.ls"
        chapterFile="${outputPath%/}.ch"

        mp3Files=($(find "$inputPath" -type f -name "*.mp3" -printf x | wc -c))
        opusFiles=($(find "$inputPath" -type f -name "*.opus" -printf x | wc -c))
        m4aFiles=($(find "$inputPath" -type f -name "*.aac" -printf x | wc -c))
        concatDone=0

        # concat
        if  ([[ $mp3Files -gt 0 && $opusFiles -eq 0 && $m4aFiles -eq 0 ]]); then
            concatMp3 "$inputPath" "$outputPath" "$listFile"
            concatDone=1
        elif ([[ $mp3Files -eq 0 && $opusFiles -gt 0 && $m4aFiles -eq 0 ]]); then
            concatOpus "$inputPath" "$outputPath" "$listFile"
            concatDone=1
        elif ([[ $mp3Files -eq 0 && $opusFiles -eq 0 && $m4aFiles -gt 0 ]]); then
            concatM4a "$inputPath" "$outputPath" "$listFile"
            concatDone=1
        fi

        if [[ $concatDone == 1 ]]; then
            # one of two ways to retrieve chapters
            # cue sheets have priority if they exist and are needed because music isn't yet split
            cueFiles=$(find "$inputPath" -type f -iname '*.cue')
            ((audioFiles = $mp3Files + $opusFiles + $m4aFiles))

            if [[ ${#cueFiles} -ge 1 && $audioFiles == 1 ]]; then
                # if there is only one audio file and a cue sheet
                # take the chapters from any cue sheet in the folder
                # this means CD1 CD2 types of input need separate folders per CD
                cueFile=$(echo "${cueFiles}" | head -1)
                chaptersFromCue "$cueFile" "$chapterFile"
            else
                # else the audio files are the chapters
                chaptersFromFiles "$listFile" "$chapterFile" 
                rm -rf "$listFile"
            fi

            # make pretty
            embedChapters "$chapterFile"
            rm -rf "$chapterFile"
            embedThumbnail "$inputPath" "$outputPath"
        fi

        ((outputFileNumber = outputFileNumber + 1))
    done

    rm -rf "$inputPathsFile"
    rm -rf "$outputPathsFile"
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

mainFunction "$inputDir" "$outputDir"

# Cleanup
find "$outputDir" -type f -name '*.ls' -delete
find "$outputDir" -type f -name '*.jpg' -delete
find "$outputDir" -type d -empty -delete