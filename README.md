[![CodeQL](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml/badge.svg)](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml)

## Local Development and Contributing

To ensure a smooth development experience, follow these steps before contributing:

1. **Set Xcode Path:** If you encounter issues, run: ```sudo xcode-select -s /Applications/Xcode.app```
   Verify that your desired iPhone model is available with: ```xcrun simctl list```

2. **Verify Project Build:** Confirm the project builds successfully with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator18.2 -destination 'platform=iOS Simulator,OS=18.2,name=iPhone 16 Pro' clean build```
   Ensure the output includes: **```** BUILD SUCCEEDED **```**

3. **Run Test Suite:** Validate the test suite passes with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator18.2 -destination 'platform=iOS Simulator,OS=18.2,name=iPhone 16 Pro' clean test```
   Check that the output includes: **```** TEST SUCCEEDED **```**

By verifying these steps on your local machine, you'll help maintain a consistent development environment for the project.
