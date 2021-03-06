unit lcc.transfer.gridconnect.message_assembler_disassembler;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}


interface

{$I lcc_compilers.inc}

uses
  Classes, SysUtils, lcc.message, lcc.types.can,
  {$IFDEF FPC}
    Generics.Collections,
  {$ELSE}
    System.Generics.Collections,
    Types,
    System.SyncObjs,
  {$ENDIF}
  lcc.types;

// TLccMessageQueue holds TLccMessages that are being received piece-meal over
// an interface such as CAN where it can't sent entire message arrays and decodes
// TCP message frames into easy and common TLccMessage structures that the application
// can use.  Pass all messages from the wire protocols through this class to receive
// a TLccMessage to use independantly of wire protocol

type

  TIncomingMessageGridConnectReply = (imgcr_False, imgcr_True, imgcr_ErrorToSend, imgcr_UnknownError);

{ TLccMessageAssembler }

TLccMessageAssembler = class
private
  FInProcessMessageList: TObjectList<TLccMessage>;
  function GetCount: Integer;
public
  property Count: Integer read GetCount;
  property Messages: TObjectList<TLccMessage> read FInProcessMessageList write FInProcessMessageList;

  constructor Create;
  destructor Destroy; override;

  procedure Add(AMessage: TLccMessage);
  procedure Clear;
  procedure Remove(AMessage: TLccMessage; DoFree: Boolean);
  function FindByAliasAndMTI(AMessage: TLccMessage): TLccMessage;
  procedure FlushMessagesByAlias(Alias: Word);
  function IncomingMessageGridConnect(LccMessage: TLccMessage): TIncomingMessageGridConnectReply;
end;

{ TLccMessageDisAssembler }

TLccMessageDisAssembler = class
public
  function OutgoingMsgToGridConnect(Msg: TLccMessage): String;
  procedure OutgoingMsgToMsgList(Msg: TLccMessage; MsgList: TStringList);
end;


implementation

{ TLccMessageDisAssembler }

function TLccMessageDisAssembler.OutgoingMsgToGridConnect(Msg: TLccMessage): String;
begin
  // Unsure if there is anything special to do here yet
  Result := Msg.ConvertToGridConnectStr(#10);
end;

procedure TLccMessageDisAssembler.OutgoingMsgToMsgList(Msg: TLccMessage; MsgList: TStringList);
begin
  if Assigned(MsgList) then
    MsgList.Text := Msg.ConvertToGridConnectStr(#10);
end;

{ TLccMessageAssembler }

function TLccMessageAssembler.GetCount: Integer;
begin
  Result := FInProcessMessageList.Count;
end;

constructor TLccMessageAssembler.Create;
begin
  inherited Create;
  FInProcessMessageList := TObjectList<TLccMessage>.Create;
  Messages.OwnsObjects := False;
end;

procedure TLccMessageAssembler.Remove(AMessage: TLccMessage; DoFree: Boolean);
begin
  Messages.Remove(AMessage);
  if DoFree then
    AMessage.Free;
end;

destructor TLccMessageAssembler.Destroy;
begin
  Clear;
  FreeAndNil(FInProcessMessageList);
  inherited Destroy;
end;

procedure TLccMessageAssembler.Add(AMessage: TLccMessage);
begin
  Messages.Add(AMessage);
end;

procedure TLccMessageAssembler.Clear;
var
  i: Integer;
begin
  try
    for i := 0 to Messages.Count - 1 do
    {$IFDEF FPC}
      Messages[i].Free
    {$ELSE}
      Messages[i].DisposeOf;
    {$ENDIF}
  finally
    Messages.Clear;
  end;
end;


function TLccMessageAssembler.FindByAliasAndMTI(AMessage: TLccMessage): TLccMessage;
var
  i: Integer;
  LccMessage: TLccMessage;
begin
  Result := nil;
  for i := 0 to Messages.Count - 1 do
  begin
    LccMessage := Messages[i];
    if (AMessage.Source.Alias = LccMessage.Source.Alias) and (AMessage.Destination.Alias = LccMessage.Destination.Alias) and (AMessage.MTI = LccMessage.MTI) then
    begin
      Result := LccMessage;
      Break
    end;
  end;
end;


procedure TLccMessageAssembler.FlushMessagesByAlias(Alias: Word);
var
  i: Integer;
  AMessage: TLccMessage;
begin
  for i := Messages.Count - 1 downto 0  do
  begin
    AMessage := Messages[i];
    if (AMessage.Source.Alias = Alias) or (AMessage.Destination.Alias = Alias) then
    begin
      if AMessage.MTI = MTI_DATAGRAM then
      {$IFDEF FPC}
        InterLockedDecrement(AllocatedDatagrams);
      {$ELSE}
        TinterLocked.Decrement(AllocatedDatagrams);
      {$ENDIF}
      Messages.Delete(i);
      AMessage.Free
    end;
  end;
end;

function TLccMessageAssembler.IncomingMessageGridConnect(LccMessage: TLccMessage): TIncomingMessageGridConnectReply;
var
  InProcessMessage: TLccMessage;
  i: Integer;
begin                                                                           // The result of LccMessage is undefined if false is returned!
  Result := imgcr_False;

  if LccMessage.CAN.Active then
  begin  // CAN Only frames
    case LccMessage.CAN.MTI of
      MTI_CAN_AMR :
        begin
          FlushMessagesByAlias(LccMessage.Source.Alias);
          Result := imgcr_True  // Pass it on
        end;
      MTI_CAN_AMD :
        begin
          FlushMessagesByAlias(LccMessage.Source.Alias);
          Result := imgcr_True  // Pass it on
        end;
      MTI_CAN_FRAME_TYPE_DATAGRAM_FRAME_ONLY :
        begin
          InProcessMessage := FindByAliasAndMTI(LccMessage);
          if Assigned(InProcessMessage) then
            Remove(InProcessMessage, True)                                         // Something is wrong, out of order.  Throw it away
          else begin
            if AllocatedDatagrams < Max_Allowed_Datagrams then
            begin
              LccMessage.CAN.Active := False;
              LccMessage.MTI := MTI_DATAGRAM;
              Result := imgcr_True
            end else
            begin
              LccMessage.LoadDatagramRejected(LccMessage.Destination, LccMessage.Source, REJECTED_BUFFER_FULL);
              Result := imgcr_ErrorToSend
            end;
          end;
        end;
      MTI_CAN_FRAME_TYPE_DATAGRAM_FRAME_START :
        begin
          InProcessMessage := FindByAliasAndMTI(LccMessage);
          if Assigned(InProcessMessage) then
            Remove(InProcessMessage, True)                                         // Something is wrong, out of order.  Throw it away
          else begin
            if AllocatedDatagrams < Max_Allowed_Datagrams then
            begin
              InProcessMessage := TLccMessage.Create;
              InProcessMessage.MTI := MTI_DATAGRAM;
              LccMessage.Copy(InProcessMessage);
              Add(InProcessMessage);
              {$IFDEF FPC}
              InterLockedIncrement(AllocatedDatagrams)
              {$ELSE}
              TInterlocked.Increment(AllocatedDatagrams)
              {$ENDIF}
            end
          end;
        end;
      MTI_CAN_FRAME_TYPE_DATAGRAM_FRAME :
        begin
          InProcessMessage := FindByAliasAndMTI(LccMessage);
          if Assigned(InProcessMessage) then
            InProcessMessage.AppendDataArray(LccMessage)
        end;
      MTI_CAN_FRAME_TYPE_DATAGRAM_FRAME_END :
        begin
          InProcessMessage := FindByAliasAndMTI(LccMessage);
          if Assigned(InProcessMessage) then
          begin
            InProcessMessage.AppendDataArray(LccMessage);
            InProcessMessage.Copy(LccMessage);
            Remove(InProcessMessage, True);
            LccMessage.CAN.Active := False;
            LccMessage.MTI := MTI_DATAGRAM;
            LccMessage.CAN.MTI := 0;
            {$IFDEF FPC}
            InterLockedDecrement(AllocatedDatagrams);
            {$ELSE}
            TInterlocked.Decrement(AllocatedDatagrams);
            {$ENDIF}
            Result := imgcr_True
          end else
          begin
            // Out of order
            LccMessage.LoadDatagramRejected(LccMessage.Destination, LccMessage.Source, REJECTED_OUT_OF_ORDER);
            Result := imgcr_ErrorToSend
          end;
        end;
      MTI_CAN_FRAME_TYPE_CAN_STREAM_SEND :
        begin

        end
    else
      Result := imgcr_True
    end
  end else
  begin
    if LccMessage.MTI = MTI_PROTOCOL_SUPPORT_INQUIRY then
      case LccMessage.CAN.FramingBits of
        $00, $10 : begin
                // This is an extended number of bit call.. currently not implented
                Result := imgcr_True;                                        // Single frame just create a message
              end
      else begin
        Result := imgcr_False;
      end;
    end else
    if LccMessage.CAN.FramingBits <> $00 then                                // Is it a Multi Frame Message?
    begin
      case LccMessage.CAN.FramingBits of                                     // Train SNIP falls under this now
        $10 : begin   // First Frame
                InProcessMessage := FindByAliasAndMTI(LccMessage);
                if Assigned(InProcessMessage) then
                  Remove(InProcessMessage, True)                              // Something is wrong, out of order.  Throw it away
                else begin
                  InProcessMessage := TLccMessage.Create;
                  LccMessage.Copy(InProcessMessage);
                  Add(InProcessMessage);
                end;
              end;
        $20 : begin   // Last Frame
                InProcessMessage := FindByAliasAndMTI(LccMessage);
                if Assigned(InProcessMessage) then
                begin
                  InProcessMessage.AppendDataArray(LccMessage);
                  InProcessMessage.Copy(LccMessage);
                  Remove(InProcessMessage, True);
                  Result := imgcr_True
                end else
                begin
                  // Out of order but let the node handle that if needed (Owned Nodes Only)
                  // Don't swap the IDs, need to find the right target node first
                  LccMessage.LoadOptionalInteractionRejected(LccMessage.Destination, LccMessage.Source, REJECTED_OUT_OF_ORDER, LccMessage.MTI);
                  Result := imgcr_ErrorToSend
                end;
              end;
        $30 : begin   // Middle Frame
                InProcessMessage := FindByAliasAndMTI(LccMessage);
                if Assigned(InProcessMessage) then
                  InProcessMessage.AppendDataArray(LccMessage)
              end;
      end;
    end else                                                                  // Is it a Multi Frame String Message?
    if (LccMessage.MTI = MTI_SIMPLE_NODE_INFO_REPLY) then
    begin
      InProcessMessage := FindByAliasAndMTI(LccMessage);
      if not Assigned(InProcessMessage) then
      begin
        InProcessMessage := TLccMessage.Create;
        LccMessage.Copy(InProcessMessage);
        for i := 0 to InProcessMessage.DataCount - 1 do
        begin
          if InProcessMessage.DataArray[i] = Ord(#0) then
            InProcessMessage.CAN.iTag := InProcessMessage.CAN.iTag + 1
        end;
        Add(InProcessMessage);
      end else
      begin
        if InProcessMessage.AppendDataArrayAsString(LccMessage, 6) then
        begin
          InProcessMessage.Copy(LccMessage);
          Remove(InProcessMessage, True);
          Result := imgcr_True;
        end
      end
    end else
      Result := imgcr_True;                                        // Single frame just create a message
  end
end;

end.

