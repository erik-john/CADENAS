# CADENAS NX File Organizer

## Description

![Version](https://img.shields.io/badge/version-3.2.13-blue)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-Windows%205.1-5391FE)
![Siemens NX](https://img.shields.io/badge/Siemens%20NX-1855%20%7C%202506-009999)

A Windows desktop utility for organizing sample components downloaded from the **CADENAS library in Siemens NX** and monitoring the completion of local standard component catalogs.

The project helps engineers build and maintain a structured NX standard parts library without manually locating the destination folder for each downloaded `.prt` file. The organizer moves matched files into their corresponding catalog folders and provides a visual overview of downloaded, incomplete and missing components.

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
