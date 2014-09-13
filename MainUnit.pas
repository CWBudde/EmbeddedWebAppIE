unit MainUnit;

interface

uses
  (* Delphi *)
  WinApi.Windows, WinApi.Messages, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls,
  Vcl.OleCtrls, ActiveX, SHDocVw,

  (* DWS *)
  dwsHTTPSysServer, dwsUtils, dwsWebEnvironment, dwsXPlatform,
  dwsWebServerHelpers,

  (* OmniXML *)
  OmniXML, OmniXMLUtils;

type
  TFormEmbeddedIE = class(TForm)
    WebBrowser: TWebBrowser;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure WebBrowserTitleChange(ASender: TObject; const Text: WideString);
    procedure FormDestroy(Sender: TObject);
  private
    FConfig: IXMLDocument;
    FIndexFileName: TFileName;
    FServer: THttpApi2Server;
    FPort: Integer;
    FMimeTypeCache: TMIMETypeCache;
    function GetIndexExt: string;
    function GetIndexName: string;
    procedure RequestHandler(Request: TWebRequest; Response: TWebResponse);
  public
    property IndexName: string read GetIndexName;
    property IndexExt: string read GetIndexExt;
  end;

  TWebBrowserHelper = class helper for TWebBrowser
  public
    procedure NavigateToURL(const URL: string);
  end;

var
  FormEmbeddedIE: TFormEmbeddedIE;

implementation

{$R *.dfm}

uses
  System.Win.Registry, System.Types, System.StrUtils, MSHTML;

function URLEncode(const URL: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(URL) do
  begin
    // replace invalid characters with a generic unicode representation
    if CharInSet(URL[Index], ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then
      Result := Result + URL[Index]
    else
      Result := Result + '%' + IntToHex(Ord(URL[Index]), 2);
  end;
end;

procedure SplitFileName(const FileName: TFileName; out Name, Ext: string);
var
  str: TStringDynArray;
begin
  // split filename into uppercase name and extension
  str := SplitString(FileName, '.');
  Name := UpperCase(str[0]);
  Ext := UpperCase(str[1]);
end;

function MakeResourceURL(const Module: HMODULE; const ResName: PChar;
  const ResType: PChar = nil): string; overload;

  function ResNameOrTypeToString(R: PChar): string;
  begin
    if HiWord(LongWord(R)) = 0 then
      Result := Format('#%d', [LoWord(LongWord(R))])
    else
      Result := R;
  end;

begin
  Assert(Assigned(ResName));
  Result := 'res://' + URLEncode(GetModuleName(Module));
  if Assigned(ResType) then
    Result := Result + '/' + URLEncode(ResNameOrTypeToString(ResType));
  Result := Result + '/' + URLEncode(ResNameOrTypeToString(ResName));
end;


{ TWebBrowserHelper }

procedure TWebBrowserHelper.NavigateToURL(const URL: string);
var
  Flags: OleVariant;
begin
  Flags := navNoHistory;
  if AnsiStartsText('res://', URL) or AnsiStartsText('file://', URL)
    or AnsiStartsText('about:', URL) or AnsiStartsText('javascript:', URL)
    or AnsiStartsText('mailto:', URL) then
    Flags := Flags or navNoReadFromCache or navNoWriteToCache;

  Self.Navigate(URL, Flags);
end;

type
  TIEMode = (iemIE7, iemIE8, iemIE9, iemIE10, iemIE11);

procedure SetBrowserEmulation(Mode: TIEMode; AppName: string = '');
const
  REG_KEY = 'Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION';
var
  Value: Integer;
begin
  // determine desired DWORD value (according to the specified browser)
  case Mode of
     iemIE7 : Value := 7000;
     iemIE8 : Value := 8888;
     iemIE9 : Value := 9999;
    iemIE10 : Value := 10001;
    iemIE11 : Value := 11001;
    else
      Exit;
  end;

  // eventually get application name (if not specified)
  if AppName = '' then
    AppName := ExtractFileName(Application.ExeName);

  // set browser emulation by writing the value to the registry
  with TRegistry.Create do
  try
    RootKey := HKEY_CURRENT_USER;
    if OpenKey(REG_KEY, True) then
    begin
      WriteInteger(AppName, Value);
      CloseKey;
    end;
  finally
    Free;
  end;
end;


{ TFormEmbeddedIE }

procedure TFormEmbeddedIE.FormCreate(Sender: TObject);
var
  RS: TResourceStream;
  Node, WidgetNode, ParamNode: IXMLNode;
  IEVersion: Integer;
  UseServer: Boolean;
  str: string;
begin
  // default
  FIndexFileName := 'INDEX.HTML';
  FPort := 8090;
  IEVersion := 11;

  if FindResource(hInstance, 'CONFIG', 'XML') <> 0 then
  begin
    FConfig := CreateXMLDoc;
    RS := TResourceStream.Create(HInstance, 'CONFIG', 'XML');
    try
      if not XMLLoadFromStream(FConfig, RS) then
        Exit;

      WidgetNode := SelectNode(FConfig, 'widget');
      ClientWidth := GetNodeAttrInt(WidgetNode, 'width', ClientWidth);
      ClientHeight := GetNodeAttrInt(WidgetNode, 'height', ClientHeight);
      str := LowerCase(GetNodeAttrStr(WidgetNode, 'viewmodes', ''));
      if (str = 'windowed') then
      begin
        BorderStyle := bsSingle;
        WindowState := wsNormal;
      end else
      if (str = 'floating') then
      begin
        BorderStyle := bsSizeable;
        WindowState := wsNormal;
      end else
      if (str = 'fullscreen') then
      begin
        BorderStyle := bsNone;
        WindowState := wsMaximized;
      end else
      if (str = 'maximized') then
      begin
        BorderStyle := bsSizeable;
        WindowState := wsMaximized;
      end else
      if (str = 'minimized') then
      begin
        BorderStyle := bsSizeable;
        WindowState := wsMinimized;
      end;

      // enum feature tags
      for Node in XMLEnumNodes(WidgetNode, 'feature') do
      begin
        // only handle 'server' feature
        if LowerCase(GetNodeAttrStr(Node, 'name', '')) = 'server' then
        begin
          // enum param tags
          for ParamNode in XMLEnumNodes(Node, 'param') do
          begin
            // only handles 'port' param
            if LowerCase(GetNodeAttrStr(ParamNode, 'name', '')) = 'port' then
              FPort := GetNodeAttrInt(ParamNode, 'value', FPort);
          end;

          UseServer := True;
        end;
      end;

      for Node in XMLEnumNodes(WidgetNode, 'preferences') do
        if LowerCase(GetNodeAttrStr(Node, 'name', '')) = 'ie' then
        begin
          // enum param tags (only handles 'version' param)
          for ParamNode in XMLEnumNodes(Node, 'param') do
            if LowerCase(GetNodeAttrStr(ParamNode, 'name', '')) = 'version' then
              IEVersion := GetNodeAttrInt(ParamNode, 'value', IEVersion);
        end;

      // update caption according to name tag
      Caption := GetNodeTextStr(WidgetNode, 'name', Caption);

      // get content source
      Node := SelectNode(WidgetNode, 'content');
      if Assigned(Node) then
        FIndexFileName := GetNodeAttrStr(Node, 'src', FIndexFileName);
    finally
      RS.Free;
    end;
  end
  else
  begin
    UseServer := FindResource(hInstance, 'APP', 'CSS') <> 0;
  end;

  if UseServer then
  begin
    FMimeTypeCache := TMIMETypeCache.Create;
    FServer := THttpApi2Server.Create(False);
    FServer.AddUrl('', FPort, False);
    FServer.OnRequest := RequestHandler;
  end;

  // set browser emulation based on IE version
  case IEVersion of
    7:
      SetBrowserEmulation(iemIE7);
    8:
      SetBrowserEmulation(iemIE8);
    9:
      SetBrowserEmulation(iemIE9);
    10:
      SetBrowserEmulation(iemIE10);
    11:
      SetBrowserEmulation(iemIE11);
  end;
end;

procedure TFormEmbeddedIE.FormDestroy(Sender: TObject);
begin
  FServer.Free;
  FMimeTypeCache.Free;
end;

procedure TFormEmbeddedIE.FormShow(Sender: TObject);
begin
  if FindResource(hInstance, PWideChar(IndexName), PWideChar(IndexExt)) <> 0 then
  begin
    if Assigned(FServer) then
      WebBrowser.Navigate(Format('http://localhost:%d/%s', [FPort, FIndexFileName]))
    else
      WebBrowser.NavigateToURL(MakeResourceURL(HInstance,
        PWideChar(IndexName), PWideChar(IndexExt)))
  end
  else
    WebBrowser.Navigate(ExtractFilePath(ParamStr(0)) + FIndexFileName);
end;

function TFormEmbeddedIE.GetIndexExt: string;
begin
  Result := ExtractFileExt(FIndexFileName);
  if Result[1] = '.' then
    Delete(Result, 1, 1);
end;

function TFormEmbeddedIE.GetIndexName: string;
begin
  Result := ChangeFileExt(FIndexFileName, '');
end;

procedure TFormEmbeddedIE.RequestHandler(Request: TWebRequest;
  Response: TWebResponse);
var
  FileName: TFileName;
  Name, Ext, Content: string;
  RS: TResourceStream;
  WriteOnlyStream: TWriteOnlyBlockStream;
begin
  FileName := ExtractFileName(StringReplace(Request.URL, '/', '\', [rfReplaceAll]));

  Response.Headers.Add('Access-Control-Allow-Origin: *');
  Response.ContentType := FMimeTypeCache.MIMEType(FileName);
  Response.ContentEncoding := 'utf-8';

  SplitFileName(FileName, Name, Ext);
  if FindResource(HInstance, PWideChar(Name), PWideChar(Ext)) <> 0 then
  begin
    RS := TResourceStream.Create(HInstance, Name, PWideChar(Ext));
    try
      WriteOnlyStream := TWriteOnlyBlockStream.Create;
      try
        WriteOnlyStream.CopyFrom(RS, RS.Size);
        Response.ContentData := WriteOnlyStream.ToRawBytes;
      finally
        WriteOnlyStream.Free;
      end;
    finally
      RS.Free;
    end;
  end
  else
  begin
    FileName := ExpandFileName(StringReplace(Request.URL, '/', '\', [rfReplaceAll]));
    if FileExists(FileName) then
    begin
      Content := LoadTextFromFile(ExpandFileName(FileName));
      Response.ContentData := ScriptStringToRawByteString(Content);
    end
    else
      Response.StatusCode := 404;
  end;
end;

procedure TFormEmbeddedIE.WebBrowserTitleChange(ASender: TObject;
  const Text: WideString);
begin
  Caption := Text;
end;

end.
