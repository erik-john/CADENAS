# CADENAS NX File Organizer

## Description

A Windows desktop utility for organizing Siemens NX sample components downloaded from the CADENAS library and tracking the completion of local standard component catalogs. Current version: **V3.2.10**.

## Screenshot

![CADENAS NX File Organizer and Standard Status Viewer](screenshot.png)

*Illustrative reconstruction of the V3.2.10 interface; example counts are not from a live scan.*

## Features

- Automatically matches and moves NX `.prt` files using CADENAS metadata, including split component files.
- Scans local catalog images to identify and count component items separately from categories.
- Displays the complete locally available catalog hierarchy, including components without folders.
- Classifies components as Completed, Incompleted or Missing.
- Shows completion percentage, status counts and a three-color segmented progress bar.
- Retains folder settings and activity logs.

## System Requirements

- Microsoft Windows with Windows PowerShell 5.1 and .NET Framework Windows Forms / System.Drawing support.
- Siemens NX with CADENAS library access (used with NX 1855 and NX 2506).
- Read/write access to local CADENAS folders and the user's Documents folder.

No additional PowerShell modules or database are required. See the [User Manual](User%20Manual.docx) for installation, usage and troubleshooting.
