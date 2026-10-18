# POC: Xcode Code Reader for Blind Learners

This repository contains a proof of concept for a macOS application that helps blind learners study Swift and Xcode by reading code aloud in the Xcode editor in more detail than a standard screen reader.

The proof of concept covers the Code Reading scope:
- Detecting when Xcode is in front and a code editor is open.
- Reading code aloud with the application's own voice.
- Evaluating how it conflicts with VoiceOver.

To run it, App Sandbox must be disabled and Accessibility permission must be granted to the application.
