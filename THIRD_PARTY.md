# External software

FOI Surround Monitor uses your local installation of FFmpeg to encode six-channel PCM to AC-3. The build copies the FFmpeg executable you select into the app on your Mac. FFmpeg's license depends on how that executable was built. Run `ffmpeg -L` to see its license. The public source download contains no FFmpeg binary. [FFmpeg licensing](https://ffmpeg.org/legal.html)

Install BlackHole 16ch separately to route audio from Fairlight to the app. The source download contains no BlackHole driver. [BlackHole project and license](https://github.com/ExistentialAudio/BlackHole)
