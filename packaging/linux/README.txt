Screen Recorder for Linux
=========================

Requirements (Ubuntu / Debian):

    sudo apt install ffmpeg libmpv2 libgtk-3-0

(On older releases the mpv library is called libmpv1.)

Run it:

    ./screen_recorder_app

Recording works on X11 and Wayland. Auto-zoom needs an X11 session,
because Wayland doesn't let apps read the mouse position.

The .deb package installs all of this for you and adds Screen Recorder
to your app menu.
