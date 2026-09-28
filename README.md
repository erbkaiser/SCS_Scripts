Repair-Traffic-Variants.ps1: * Repairs outdated variant attributes in traffic_vehicle and traffic_trailer unit definitions.
after https://gist.github.com/RainBawZ/3b590d7395c22fecfacdad91dece1270

Update-Daytime.ps1: Updates day_in_year, its date comment, and summer_time for ETS2 and ATS env_profile files.

Update-ManifestCompatibility.ps1: * Finds compatible_versions entries for the previous game version and updates ZIPFS or HashFS
archives to the configured target version. Accepts a folder or one .scs/.zip archive.

Zipfs-Repack-Check.ps1: * Checks ZIPFS mod archives and tests repacking them as HashFS.

replace-sound-move.ps1:  Compares two folders with vehicle .sui files and copies sound_move lines from source to destination

* : requires helper .psm1 scripts to function
