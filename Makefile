.PHONY: dev test test-once build lint fmt run clean check

# Run the server with auto-reload on code changes
dev:
	cargo watch -x run

# Run tests with auto-reload
test:
	cargo watch -x test

# Run tests once
test-once:
	cargo test

# Build the project
build:
	cargo build

# Run linter
lint:
	cargo clippy -- -D warnings

# Format code
fmt:
	cargo fmt

# Run the server (production-like)
run:
	cargo run

# Clean build artifacts
clean:
	cargo clean

# Run all checks (fmt, lint, test)
check: fmt lint test-once
