# Releasing Clops

Clops uses strict stable Semantic Versioning tags in the form `vMAJOR.MINOR.PATCH`. The first release is `v0.1.0`.

`MARKETING_VERSION` is the user-visible release version and must match the tag without its leading `v`. `CURRENT_PROJECT_VERSION` is the App Store build number: keep it as a positive integer and increment it for every App Store upload, including retries of the same release version. Each tagged release must use a build number greater than the preceding tagged release.

## Cut a release

1. Update the Clops target's Version in both Debug and Release to the next SemVer value. Increment Build for every App Store upload.
2. Commit the version change to `main`, push it, wait for CI to pass, and record that commit's full SHA as the candidate SHA.
3. Follow [MAC_APP_STORE.md](MAC_APP_STORE.md) to archive, sign, and validate the App Store candidate from that exact SHA. Tag after the candidate is accepted or otherwise ready to release.
4. Create and push an annotated tag from that commit:

   ```sh
   git switch main
   git pull --ff-only
   clops_release_sha=FULL_40_CHARACTER_CANDIDATE_SHA
   git merge-base --is-ancestor "$clops_release_sha" origin/main
   git tag -a v0.1.0 "$clops_release_sha" -m "Clops 0.1.0"
   git push origin v0.1.0
   ```

   Replace the SHA placeholder with the candidate recorded in step 2, and replace `0.1.0` with the committed version for later releases. Push one release tag at a time and wait for its Release workflow to finish. Tags must always move forward; never move or delete a published release tag.

Publishing a GitHub release before App Store acceptance locks that source version. Any later App Store retry that changes tracked source, project, entitlement, or signing configuration must use a new patch version and tag; never retarget the existing tag.

The Release workflow validates the tag, Xcode versions, increasing build number, and MAS build settings; confirms the tag belongs to `main`; runs the tests and analyzer; and archives an unsigned universal `arm64 + x86_64` MAS-configured build. It then creates a GitHub Release with generated notes and source archives.

GitHub Releases intentionally do not contain an unsigned app or the MAS upload package. Build the signed App Store package separately using [MAC_APP_STORE.md](MAC_APP_STORE.md); those signing credentials never enter normal CI.
