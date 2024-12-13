I wanted audio files with chapters for gapless playback on mobile.
And also to embed a nice thumbnail into that long chapterized audio file.
The typical audio formats support this, but it turned out no software could do it all.
- ffmpeg could do the concatenation into one file.
- It couldn't embed the chapters, which mkvtoolnix can do.
- It also couldn't embed the thumbnail, which mutagen can do.
- Finally, I found nothing that writes a chapter file based on the smaller concatenated files.

I found myself executing the same couple of terminal commands all the time and decided to make this script.

Usage:
./concatAudio <inputDir> <outputDir>
    
Default behavior
================
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
priority: embed cover from image file(s) in input folder
fallback: extract from pdf documents instead
fallback: extract from audio files themselves

Dependencies
============
ffmpeg
mkvtoolnix
pdftoppm
imagemagick
wc
mutagen

Todo List
=========
depend a lot less on temp files and do much more in RAM
avoid temporary name files, and also the chapter- and thumbnail files

rewrite in different programming language and use standard time packages,
especially for the chapter file conversion functions
