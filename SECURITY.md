# Security and privacy

Volume Knob is intentionally local-only.

- It makes no network requests.
- It does not include analytics or crash-reporting services.
- It requests microphone access only when Auto or Microphone spectrum mode is used.
- It requests Screen Recording access for Mac-audio spectrum analysis and user-initiated PNG or MP4 screen capture.
- Screen captures are saved only to the local folder selected by the user and are never uploaded.
- It may request Apple Events access to read playback metadata and control Music or Spotify when those features are used.
- Audio is analyzed in memory for the visualization and is never recorded, saved, or transmitted.
- The noise detector analyzes microphone levels in memory and stores no audio or event history.
- Privacy Noise is generated locally and makes no network connection.
- It does not request camera, contacts, or location access.
- Outside explicit capture and media-control actions, it changes only the current macOS output volume, mute state, and in-app audio processing.

To report a security issue, open a private security advisory in the repository rather than a public issue.
