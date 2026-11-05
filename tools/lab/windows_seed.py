#!/usr/bin/env python3
"""Create unattended setup media for a marked disposable Windows VM only."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parents[2]
TOOLS = Path.home() / '.cache/usbless-dualboot/lab-tools/root'


def run(program, args):
    return subprocess.run([str(TOOLS / 'usr/bin' / program), *map(str,args)],
        env=dict(os.environ,LD_LIBRARY_PATH=str(TOOLS/'usr/lib')), check=True, capture_output=True, text=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=REPO/'.lab/seeds/windows-base')
    parser.add_argument('--image-name',default='Windows 11 Pro')
    parser.add_argument('--language',default='de-DE')
    args=parser.parse_args()
    output=args.output.resolve()
    if not output.is_relative_to(REPO/'.lab'):
        raise ValueError('Seed media must stay inside the private repository lab directory')
    if (output/'seed.img').exists():
        raise ValueError('Seed already exists; credentials and media are never silently replaced')
    exe=REPO/'platforms/windows/bin/Release/usbless.exe'
    if not exe.is_file():
        raise ValueError('Build the Windows executable before creating a seed')
    output.mkdir(parents=True,exist_ok=True)
    cache=REPO/'.lab/cache'
    cache.mkdir(exist_ok=True)
    pester=cache/'Pester.5.7.1.nupkg'
    if not pester.exists():
        partial=pester.with_suffix('.part')
        urllib.request.urlretrieve('https://www.powershellgallery.com/api/v2/package/Pester/5.7.1',partial)
        partial.replace(pester)
    token=secrets.token_hex(32)
    password='Lab-'+secrets.token_urlsafe(20)+'!'
    (output/'agent.json').write_text(json.dumps({'token':token})+'\n')
    (output/'credentials.json').write_text(json.dumps({'username':'LabAdmin','password':password,'token':token})+'\n')
    shutil.copyfile(REPO/'tools/lab/guest-agent.ps1',output/'guest-agent.ps1')
    shutil.copyfile(REPO/'tools/lab/windows-layout.cmd',output/'windows-layout.cmd')
    (output/'USBDB-LAB.marker').write_text('USBless disposable VM installation seed\n')
    with zipfile.ZipFile(output/'payload.zip','w',compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(exe,'usbless.exe')
        archive.write(REPO/'tools/lab/case-fedora-kde.ps1','case-fedora-kde.ps1')
        source=REPO/'platforms/windows'
        for folder in ['engine','tests','src']:
            for path in sorted((source/folder).rglob('*')):
                if path.is_file(): archive.write(path,'source/'+path.relative_to(source).as_posix())
        # The existing test loader expects the compiled app beside its source tree.
        archive.write(exe,'source/bin/Release/usbless.exe')
        with zipfile.ZipFile(pester) as package:
            for member in package.infolist():
                if member.is_dir() or member.filename.startswith(('_rels/','package/')): continue
                archive.writestr('Pester/'+member.filename,package.read(member))
    shutil.copyfile(REPO/'tools/lab/windows-bootstrap.ps1',output/'bootstrap.ps1')
    first_logon=r'''$seed=(Get-Volume | Where-Object FileSystemLabel -eq 'USBDBSEED' | Select-Object -First 1).DriveLetter; & "$seed`:\bootstrap.ps1"'''
    encoded=base64.b64encode(first_logon.encode('utf-16le')).decode('ascii')
    language=escape(args.language)
    image=escape(args.image_name)
    secret=escape(password)
    component='processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    # The disk wipe is guarded inside the same WinPE command that creates the
    # layout. Even a misplaced seed refuses to wipe an ordinary physical PC.
    layout_command=escape(r'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %d:\USBDB-LAB.marker call %d:\windows-layout.cmd')
    xml=f'''<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" {component}>
      <SetupUILanguage><UILanguage>{language}</UILanguage></SetupUILanguage>
      <InputLocale>{language}</InputLocale><SystemLocale>{language}</SystemLocale><UILanguage>{language}</UILanguage><UserLocale>{language}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" {component}>
      <DynamicUpdate><Enable>false</Enable></DynamicUpdate>
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Description>Guarded disposable-disk layout</Description><Path>{layout_command}</Path><WillReboot>Never</WillReboot></RunSynchronousCommand></RunSynchronous>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>{image}</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>USBless Lab</FullName><Organization>Disposable VM tests</Organization><ProductKey><WillShowUI>Never</WillShowUI></ProductKey></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" {component}><ComputerName>USBL-VM</ComputerName><TimeZone>UTC</TimeZone></component>
    <component name="Microsoft-Windows-LUA-Settings" {component}><EnableLUA>false</EnableLUA></component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" {component}><InputLocale>{language}</InputLocale><SystemLocale>{language}</SystemLocale><UILanguage>{language}</UILanguage><UserLocale>{language}</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" {component}>
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>LabAdmin</Name><DisplayName>USBless Lab</DisplayName><Group>Administrators</Group><Password><Value>{secret}</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>LabAdmin</Username><LogonCount>100</LogonCount><Password><Value>{secret}</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>Initialize disposable test agent</Description><CommandLine>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}</CommandLine></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
'''
    (output/'Autounattend.xml').write_text(xml)
    image_path=output/'seed.img'
    run('mformat',['-i',image_path,'-C','-F','-T','262144','-v','USBDBSEED','::'])
    for filename in ['Autounattend.xml','bootstrap.ps1','guest-agent.ps1','agent.json','payload.zip',
                     'windows-layout.cmd','USBDB-LAB.marker']:
        run('mcopy',['-i',image_path,output/filename,'::/'+filename])
    print(json.dumps({'seed':str(image_path),'payload_bytes':(output/'payload.zip').stat().st_size}))


if __name__=='__main__':
    try: main()
    except (OSError,ValueError,subprocess.CalledProcessError) as error:
        print('error:',error,file=sys.stderr)
        raise SystemExit(1)
