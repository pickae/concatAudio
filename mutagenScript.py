import sys
import base64
from mutagen.oggopus import OggOpus
from mutagen.flac import Picture

def replace_cover_art(opus_file_path, cover_art_path):
    # Load the Opus file
    audio = OggOpus(opus_file_path)

    # Check if the Opus file has any existing artwork
    if 'METADATA_BLOCK_PICTURE' in audio.tags:
        # Remove the existing cover art
        del audio.tags['METADATA_BLOCK_PICTURE']

    pic = Picture()
    pic.mime = 'image/jpeg'
    with open(cover_art_path, 'rb') as thumbfile:
        pic.data = thumbfile.read()
    pic.type = 3  # front cover

    audio['METADATA_BLOCK_PICTURE'] = base64.b64encode(pic.write()).decode('ascii')

    # Save the modified Opus file
    audio.save()

if __name__ == '__main__':
    # Get the Opus file path and cover art image file path from command-line arguments
    opus_file_path = sys.argv[1]
    cover_art_path = sys.argv[2]

    # Call the function with the provided parameters
    replace_cover_art(opus_file_path, cover_art_path)