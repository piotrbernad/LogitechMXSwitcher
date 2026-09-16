.PHONY: build lint test devices install uninstall clean

build:
	@Scripts/build.sh

lint:
	@Scripts/lint.sh

test: lint
	@DEVELOPER_DIR=$${DEVELOPER_DIR:-/Library/Developer/CommandLineTools} swift run -c release mxswitch-tests

devices:
	@DEVELOPER_DIR=$${DEVELOPER_DIR:-/Library/Developer/CommandLineTools} swift run -c release mxswitchd devices --verbose

install: build
	@rm -rf "/Applications/MX Switch.app"
	@cp -R "dist/MX Switch.app" /Applications/
	@echo "Installed to /Applications/MX Switch.app"
	@open "/Applications/MX Switch.app"

uninstall:
	@osascript -e 'do shell script "launchctl bootout system/co.bernad.mxswitch 2>/dev/null; rm -f /Library/LaunchDaemons/co.bernad.mxswitch.plist /usr/local/libexec/mxswitchd" with administrator privileges'
	@rm -rf "/Applications/MX Switch.app"
	@echo "Removed the app and the background service."

clean:
	@rm -rf .build dist
