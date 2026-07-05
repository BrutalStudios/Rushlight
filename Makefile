.PHONY: app run test icon clean

# Build Rushlight.app into ./build
app:
	bash Scripts/build_app.sh

# Build and launch the app
run: app
	open build/Rushlight.app

test:
	swift test

# Regenerate Support/Rushlight.icns
icon:
	swift Scripts/make_icon.swift build/Rushlight.iconset
	iconutil -c icns build/Rushlight.iconset -o Support/Rushlight.icns
	rm -rf build/Rushlight.iconset

clean:
	rm -rf .build build
