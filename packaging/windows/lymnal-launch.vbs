' Starts lymnal with no visible console window. lymnal is a console program, so
' launching it directly would flash a black window at every login; running it
' through this script with window style 0 keeps the always-on service invisible,
' the way a Windows service would be. Non-blocking (False), so login continues.
Dim fso, here
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run """" & here & "\lymnal.exe""", 0, False
