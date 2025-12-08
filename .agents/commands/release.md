# Release Prise

You are preparing a new release for Prise. Follow these steps:

## 1. Determine the new version

Look at the current version in `build.zig.zon` and ask the user what the new version should be (major, minor, or patch bump), or if they've already specified one, use that.

## 2. Update the version

Edit `build.zig.zon` to update the `.version` field to the new version.

## 3. Generate release subtitle

Generate 5 creative subtitle options for the release based on **The Amory Wars** universe (Coheed and Cambria). Draw from:
- Song titles, lyrics, or phrases from the albums
- Characters (Claudio, Ambellina, The Crowing, IRO-Bots, Wilhelm Ryan, etc.)
- Locations (House Atlantic, Silent Earth, Keywork, Heaven's Fence, etc.)
- Concepts (The Willing Well, The Ring in Return, Apollo, The Afterman, etc.)

Present the 5 options numbered and ask the user to pick one, or offer to generate 5 more options.

## 4. Create release notes

Create a new file at `docs/releases/vX.Y.Z.md` (matching the new version). Use `docs/releases/v0.1.0.md` as a template for the format. Include:

- A release title with the chosen subtitle (e.g., `v0.2.0 — "The Crowing"`)
- A "Highlights" section with the most important changes
- A "Features" section with detailed feature descriptions
- Any breaking changes or migration notes if applicable
- Known limitations

To populate the release notes, run `git log --oneline $(git describe --tags --abbrev=0)..HEAD` to see all commits since the last release.

## 5. Pre-release verification

Run these commands and fix any issues:
1. `zig build fmt`
2. `zig build`
3. `zig build test`

## 6. Commit and tag

After verification passes:
1. Stage all changes: `git add build.zig.zon docs/releases/`
2. Commit the version bump and release notes: `git commit -m "release: vX.Y.Z"`
3. Create the tag: `git tag vX.Y.Z`

## 7. Push (only if user confirms)

Ask the user if they want to push the tag. If confirmed:
1. `git push origin main`
2. `git push origin vX.Y.Z`

This will trigger the GitHub Actions release workflow which will:
- Build binaries for all platforms (macOS arm64/x86_64, Linux x86_64)
- Create a GitHub Release with the release notes
- Trigger the Homebrew tap update (if configured)
