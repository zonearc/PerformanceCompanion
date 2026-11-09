Release notes, one file per version (v3.0.8.md and so on).

Committing a new notes file to main publishes that release automatically
(.github/workflows/release.yml): it reads SCRIPT_VERSION from
PerformanceCompanion.ahk, checks a matching notes file exists, then creates
the tag and release with PerformanceCompanion-<version>.ahk attached.
Versions that are already released are skipped. Actions > Release > Run
workflow does the same by hand.
