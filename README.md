Except for Update-Daytime.ps1, these scripts require scs_extractor.exe and scs_packer.exe to exist somewhere on your %PATH or their location must be manually provided with -ToolsFolder "C:\Tools" where that is the valid location.
Available at https://modding.scssoft.com/wiki/Documentation/Tools/Game_Archive_Extractor & https://modding.scssoft.com/wiki/Documentation/Tools/Game_Archive_Packer

Find-ArchiveFilename.ps1: § Searches loose files recursively when Path is a folder. It also searches the text
contents of .sui files.

Repair-Traffic-Variants.ps1: § ¶ Repairs outdated variant attributes in traffic_vehicle and traffic_trailer unit definitions.
after https://gist.github.com/RainBawZ/3b590d7395c22fecfacdad91dece1270

Update-Daytime.ps1: Updates day_in_year, its date comment, and summer_time for ETS2 and ATS env_profile files.

Update-ManifestCompatibility.ps1: § Finds compatible_versions entries for the previous game version and updates ZIPFS or HashFS
archives to the configured target version. Accepts a folder or one .scs/.zip archive.

Zipfs-Repack-HashFS2.ps1: § Checks ZIPFS mod archives and repacks them as HashFS.

replace-sound-move.ps1:  Compares two folders with vehicle .sui files and copies sound_move lines from source to destination

Repair-Traffic-Variants-HashFSv2.ps1: § ¶ Combines functionality of Repair-Traffic-Variants and Zipfs-Repack-HashFS2 into one operation

§ : requires helper .psm1 scripts to function. Scripts run in test mode by default, use -ApplyFixes or -Apply or -Fix to edit archives

¶ : not covered by the Unlicense license. Copyright follows Rainbawz's implicit license
