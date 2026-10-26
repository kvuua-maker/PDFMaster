# PDF Master

A focused, paid PDF toolkit for iOS: create, convert, organise, protect and sign.

## Structure

```
PDFMaster/
  App/            app shell, premium home grid, diagnostics screen
  Diagnostics/    on-device log (shareable)
  Modules/PDFModule/
    Engine/       PDFKit + Vision + UIGraphicsPDFRenderer engine
    Model/        observable state and actions
    Views/        workspace, tools, crop, annotations, signature, scanner
Config/           build settings and the AI token
project.yml       XcodeGen source of truth (the .xcodeproj is generated in CI)
.github/workflows/testflight.yml   archive → TestFlight
```

## Build locally

```sh
brew install xcodegen
xcodegen generate
open PDFMaster.xcodeproj
```

## CI

The workflow generates the project, archives unsigned, signs with a profile
created through the App Store Connect API and uploads to TestFlight. Secrets:
`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `TEAM_ID`.
