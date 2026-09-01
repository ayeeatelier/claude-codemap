# LSP companion setup

Claude Code can use a language server through its LSP plugins (goToDefinition, findReferences, documentSymbol, call hierarchy). The codemap handles "what and why"; LSP handles "where exactly". Most language servers work with little setup once the language's LSP plugin is installed.

Swift with `.xcodeproj` is the awkward one: sourcekit-lsp needs a build-server config.

```sh
brew install xcode-build-server
xcode-build-server config -project YourApp.xcodeproj -scheme YourApp
echo buildServer.json >> .gitignore   # contains machine-local DerivedData paths
```

Build once in Xcode to populate the index store. Cross-file queries start working a few seconds after the first file is opened.
