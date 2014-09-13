program EmbeddedIE;

{$IFDEF StaticResources}
{$R 'Static.res' 'Static.rc'}
{$ENDIF}

uses
  System.SysUtils,
  Vcl.Forms,
  Vcl.Dialogs,
  MainUnit in 'MainUnit.pas' {FormEmbeddedIE};

{$R *.res}

begin
  // check if an embedded index.html is found...
  if (FindResource(hInstance, 'INDEX', 'HTML') = 0) and
     (FindResource(hInstance, 'CONFIG', 'XML') = 0) and
     not FileExists(ExtractFilePath(ParamStr(0)) + 'index.html') then
  begin
    MessageDlg('No embedded index.html / config.xml found!', mtError, [mbOK], 0);
    Exit;
  end;

  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormEmbeddedIE, FormEmbeddedIE);
  Application.Run;
end.

