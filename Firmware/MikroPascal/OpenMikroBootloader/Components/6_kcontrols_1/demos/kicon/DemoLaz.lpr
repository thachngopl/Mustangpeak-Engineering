program DemoLaz;

uses
  Interfaces,
  Forms,
  Main in 'Main.pas' {MainForm}, LResources;

{$R *.res} 

begin
  {$I DemoLaz.lrs}
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
