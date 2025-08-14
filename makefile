.PHONY: run
run:
	flutter run

.PHONY: release
release:
	flutter clean
	flutter pub get
	flutter run --release

.PHONY: build
build:
	flutter clean
	flutter pub get
	flutter build macos --release
