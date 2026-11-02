using System.ComponentModel;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views.Account;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>Mac PlansSheet：900×822 方案、积分明细、邀请好友与浏览器付款结果。</summary>
public static class PlansDialog
{
    public static void Show(FrameworkElement owner)
    {
        var view=new PlansView();
        V3Overlay.Show(owner.XamlRoot,close=>{view.Close=close;return V3Dialog.Frame(view,900);},dismissed:()=>view.Dispose());
    }
}
internal sealed partial class PlansView : Grid,IDisposable
{
    readonly CancellationTokenSource _life=new();readonly string _account=App.Session.User?.Id??"";
    JsonNode? _card,_ticket,_invite;string _status="loading",_group="",_extra="",_busy="",_error="",_ticketId="",_openUrl="",_inviteText="",_inviteError="";bool _disposed,_checking;
    readonly Dictionary<string,string> _picks=[];
    public Action Close=()=>{};
    List<JsonNode> Groups=>_card.Items("groups");
    JsonNode? ActiveGroup=>Groups.FirstOrDefault(x=>x.Text("id")==_group)??Groups.FirstOrDefault();
    List<JsonNode> Items=>_card.Items("items").Where(x=>Groups.Count<=1||x.Text("group")==ActiveGroup.Text("id")).ToList();
    string PickKey=>ActiveGroup.Text("id") is {Length:>0} key?key:"__items";
    JsonNode? Selected=>Items.FirstOrDefault(x=>x["action"] is not null&&x.Text("id")==_picks.GetValueOrDefault(PickKey))??Items.FirstOrDefault(x=>x["action"] is not null&&x.Bool("featured"))??Items.FirstOrDefault(x=>x["action"] is not null);
    string Phase=>_ticketId.Length==0?"idle":_ticket is null||_ticket.Text("state")=="pending"?"waiting":_ticket.Text("state");
    bool Locked=>Phase=="waiting";
    public PlansView(){Height=822;Padding=new(32,24,32,24);Loaded+=async(_,_)=>await Load();App.Session.PropertyChanged+=Changed;}
    void Changed(object? sender,PropertyChangedEventArgs e){if(App.Session.User?.Id!=_account||App.Session.Phase!=DrawOffer.Core.Session.SessionViewModel.SessionPhase.SignedIn)Close();}
    public void Dispose(){if(_disposed)return;_disposed=true;_life.Cancel();_support?.Close();App.Session.PropertyChanged-=Changed;}
    async Task<JsonNode> Request(string path,string method="GET",JsonNode? body=null,Dictionary<string,string>? query=null)
    {try{var value=await App.Session.Api.CareerRequestAsync(path,method,query,body,_life.Token);if(_disposed||App.Session.User?.Id!=_account)throw new OperationCanceledException();return value;}catch{if(_disposed||App.Session.User?.Id!=_account)throw new OperationCanceledException();throw;}}
    async Task Load(){_status="loading";Render();try{_card=(await Request("/api/agent/cards/plans"))["card"]?.DeepClone();_status=_card is null?"empty":"ready";}catch(OperationCanceledException){return;}catch{_status="error";}Render();}
    void Render()
    {
        if(_disposed)return;Children.Clear();var main=new Grid();main.RowDefinitions.Add(new(){Height=Auto});main.RowDefinitions.Add(new(){Height=Star()});
        if(_card is null){main.Children.Add(VStack(12,Serif("我的额度",28).Frame(height:52),Sans(_status=="loading"?"正在加载方案…":_status=="error"?"暂时无法读取方案，请重试。":"暂无可用方案",14,Sub),_status=="loading"?null:new V3Button("重试",()=>_=Load())));}
        else{
            var tabs=HStack(12);foreach(var group in Groups.Count==0?new[]{("__items","方案")}:Groups.Select(x=>(x.Text("id"),x.Text("label"))))tabs.Children.Add(Tab(group.Item2,_extra.Length==0&&(group.Item1==ActiveGroup.Text("id")||group.Item1=="__items"),()=>{_group=group.Item1;_extra="";Render();}));
            tabs.Children.Add(Tab("积分明细",_extra=="credits",()=>{_extra="credits";if(_creditsState.Length==0)_=LoadCredits();else Render();}));tabs.Children.Add(Tab("邀请好友",_extra=="invite",()=>{_extra="invite";if(_inviteState.Length==0)_=LoadInvite();else Render();}));
            var header=VStack(16,Spread(Serif(_card.Text("title"),28).Frame(height:52),Sans(_card.Text("status"),14,Txt,Medium)).Pad(0,0,48,0),Spread(tabs,AccountPage.LinkButton("会员与积分说明 ↗",()=>WebBridge.Open("/pricing/credits")),12));main.Children.Add(header);
            FrameworkElement content=_extra=="credits"?Credits():_extra=="invite"?Invite():Plans();content.Top(16);Grid.SetRow(content,1);main.Children.Add(content);
        }
        Children.Add(main);Children.Add(V3Dialog.CloseButton(Close).Align(HorizontalAlignment.Right,VerticalAlignment.Top).Pad(0,2,-6,0));
    }
    static FrameworkElement Tab(string label,bool active,Action action){var button=new V3Button(label,action,V3Button.Kind.Text){Width=96,Height=40,TextSize=14};return new Border{Child=button,BorderBrush=Brush(Txt),BorderThickness=new(0,0,0,active?2:0)};}
    FrameworkElement Plans()
    {
        var grid=new Grid();grid.RowDefinitions.Add(new(){Height=Auto});grid.RowDefinitions.Add(new(){Height=Star()});grid.RowDefinitions.Add(new(){Height=Auto});grid.Children.Add(Sans(_card.Text("text"),12,Sub).Frame(height:20));var cards=new Grid{ColumnSpacing=18};
        var items=Items;for(var i=0;i<items.Count;i++){cards.ColumnDefinitions.Add(new(){Width=Star()});var card=PlanCard(items[i]);Grid.SetColumn(card,i);cards.Children.Add(card);}cards.Margin=new(0,16,0,0);Grid.SetRow(cards,1);grid.Children.Add(cards);
        if(Selected is {} selected&&selected["action"] is {} action){var checkout=Checkout(selected,action);Grid.SetRow(checkout,2);grid.Children.Add(checkout);}return grid;
    }
    FrameworkElement PlanCard(JsonNode item)
    {
        var selectable=item["action"] is not null;var on=selectable&&Selected.Text("id")==item.Text("id");var badge=item.Text("badge");var head=Spread(HStack(8,selectable?Sans(on?"●":"○",16,on?Txt:Hex(0xCFCFCA)):null,Sans(item.Text("title"),14,Txt,Medium)),badge.Length==0?new Grid():Fill(item.Bool("featured")?Hex(0xEEF3FD):Field,item.Bool("featured")?10:6,child:Sans(badge,11.5,item.Bool("featured")?Blue:Sub,Medium)).WithPadding(new(8,2,8,2)),8);
        var body=VStack(16,head);if(item.Text("price").Length>0){body.Children.Add(HStack(6,Label(item.Text("price"),34,Txt,Semibold).Frame(height:55),Sans(item.Text("period"),12,Sub)));if(item["analogy"] is {} analogy)body.Children.Add(Fill(Hex(0xFDF1E3),14,child:HStack(6,Icon("sparkle",12,Orange),Sans(analogy.Text("text"),13.5,Hex(0x9A5A1C),Medium))).WithPadding(new(10,4,12,4)));}
        if(item.Text("headline").Length>0||item.Text("subline").Length>0)body.Children.Add(VStack(5,Sans(item.Text("headline"),20,Txt,Medium).Frame(height:32),Sans(item.Text("subline"),11.5,Sub).Wrap().LineHeight(19),Divider(Cl).Top(16)));
        var lines=VStack(10);foreach(var line in item.Items("lines"))lines.Children.Add(Columns(8,(Px(14),Icon("checkmark",10,on?Blue:Fnt)),(Star(),Sans(line.GetValue<string>(),13,Sub).Wrap().LineHeight(21))));body.Children.Add(lines);if(item.Text("note").Length>0)body.Children.Add(Sans(item.Text("note"),12,Sub).Wrap());
        var card=Card(body,14,new Thickness(24),selectable?White:Hex(0xFCFCFB),on?Txt:Cl);card.BorderThickness=new(on?1.5:1);card.Opacity=(Locked||_busy.Length>0)&&!on ? .55 : 1;card.IsTabStop=selectable;card.PointerReleased+=(_,_)=>Choose();card.KeyDown+=(_,e)=>{if(e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space){e.Handled=true;Choose();}};void Choose(){if(selectable&&!Locked&&_busy.Length==0){_picks[PickKey]=item.Text("id");Render();}}return card;
    }
    FrameworkElement Checkout(JsonNode selected,JsonNode action)
    {
        var left=VStack(6);if(Phase=="idle"){
            var config=_card?["invite"];
            if(config is not null&&Items.Any(x=>x["action"] is not null&&x.Text("group")==config.Text("group"))){
                if(selected.Text("group")==config.Text("group"))left.Children.Add(Coupon(config));
                else left.Children.Add(Sans("积分包长期有效，不使用邀请码",12.5,Fnt));
            }
        }else{
            var waiting=Phase=="waiting";var tone=waiting?Blue:Phase=="done"?Green:Phase=="closed"?Sub:Hex(0xC9781A);
            var background=waiting?Hex(0xEEF3FD):Phase=="done"?Hex(0xEAF6EE):Phase=="closed"?Field:Hex(0xFDF3E7);
            var text=VStack(4,Sans(waiting?"请在新打开的支付宝页面完成付款":_ticket.Text("text"),14,Txt,Medium).Wrap());
            if(waiting)text.Children.Add(HStack(10,Sans("订单 15 分钟内有效，付款后这里会自动更新",12.5,Sub),AccountPage.LinkButton("重新打开",()=>OpenPayment(_openUrl))));
            left.Children.Add(HStack(12,Fill(background,18,36,36,Icon(waiting?"arrow.triangle.2.circlepath":Phase=="done"?"checkmark":Phase=="closed"?"info.circle":"exclamationmark.circle",15,tone).Align(HorizontalAlignment.Center,VerticalAlignment.Center)),text));
        }
        var right=HStack(16);if(Phase is "idle" or "waiting" or "closed"){var priced=Phase=="idle"?_invite?["prices"]?[action.Text("id")]:null;var amount=priced.Text("price");if(amount.Length==0)amount=action.Text("amount");if(amount.Length==0)amount=selected.Text("price");right.Children.Add(VStack(2,HStack(8,Sans("应付",13,Sub),priced is null?null:Strike(Label(priced.Text("original"),13,Fnt)),Label(amount,26,Txt,Semibold)),Sans(action.Text("caption"),11.5,Fnt)));}
        var done=Phase is "done" or "review" or "refunded";var button=new V3Button(Phase=="waiting"?"等待付款结果":done?"知道了":_busy.Length>0?"正在处理…":action.Text("label"),()=>{if(done)_=Finish();else _=Run(action.Text("id"));},Phase is "review" or "refunded"?V3Button.Kind.Ghost:V3Button.Kind.Dark,height:48){Enabled=!Locked&&_busy.Length==0,MinWidth=140,CornerRadius=new(10)};right.Children.Add(button);
        return VStack(12,Divider(Cl),Spread(left,right,16).Top(12),_error.Length==0?null:Sans(_error,14,Red).Wrap()).Top(24);
    }
    FrameworkElement Coupon(JsonNode config)
    {
        if(_invite is not null)return Fill(Hex(0xEEF3FD),12,340,48,Spread(HStack(10,Icon("ticket",13,Blue),Sans(_invite.Text("code"),14,Txt,Medium),Sans("已减 "+_invite.Text("discount"),13,Blue)),AccountPage.LinkButton("移除",()=>{if(_busy.Length>0)return;_invite=null;_inviteText=_inviteError="";Render();})).Pad(14,0,14,0));
        var input=AccountPage.Input(_inviteText,config.Text("label"),36);input.Width=216;input.BorderThickness=new(0);input.Background=Brush(Clear);input.MaxLength=32;input.PlaceholderText=config.Text("label")+(config.Text("entry").Length>0?"，"+config.Text("entry"):"");
        var use=new V3Button(_checking?"正在核对…":"使用",()=>_=CheckInvite(),height:36){Enabled=!_checking&&_inviteText.Trim().Length>0};input.TextChanged+=(_,_)=>{_inviteText=input.Text.ToUpperInvariant();_inviteError="";use.Enabled=!_checking&&_inviteText.Trim().Length>0;};input.KeyDown+=(_,e)=>{if(e.Key==Windows.System.VirtualKey.Enter){e.Handled=true;_=CheckInvite();}};
        var frame=new Grid{Width=340,Height=48};var outline=new Microsoft.UI.Xaml.Shapes.Rectangle{RadiusX=12,RadiusY=12,Stroke=Brush(Hex(0x9DB7EC)),StrokeThickness=1.5,StrokeDashArray=new Microsoft.UI.Xaml.Media.DoubleCollection{5,3},IsHitTestVisible=false};frame.Children.Add(outline);frame.Children.Add(HStack(6,Icon("ticket",13,Blue),input,use).Pad(14,0,6,0));frame.Tip("邀请券");return VStack(4,frame,_inviteError.Length>0?Sans(_inviteError,12,Red):null);
    }
    async Task CheckInvite(){if(_checking||_inviteText.Trim().Length==0)return;_checking=true;_inviteError="";try{_invite=await Request("/api/billing/invite-codes/check","POST",new JsonObject{["code"]=_inviteText.Trim()});}catch(OperationCanceledException){return;}catch{_invite=null;_inviteError="邀请码不可用，请检查后重试。";}finally{_checking=false;}Render();}
    string _attemptAction="",_attemptKey="",_attemptCode="";
    async Task Run(string id)
    {
        if(_busy.Length>0||Locked)return;_busy=id;_error="";Render();
        var code=_invite?["prices"]?[id] is not null?_invite.Text("code"):"";if(_attemptAction!=id||_attemptCode!=code||_attemptKey.Length==0){_attemptAction=id;_attemptCode=code;_attemptKey=Guid.NewGuid().ToString("N");}
        try{var body=new JsonObject{["idempotency_key"]=_attemptKey};if(code.Length>0)body["invite_code"]=code;var result=await Request("/api/agent/actions/"+id,"POST",body);_ticketId=result.Text("ticket");_openUrl=result.Text("open_url");_ticket=null;if(_ticketId.Length==0)throw new InvalidDataException();_=Poll();OpenPayment(_openUrl);}
        catch(OperationCanceledException){return;}catch(ApiException ex){_error="暂时无法处理，请稍后再试。";if((int)ex.Status is >=400 and <500)_attemptKey="";}catch{_error="暂时无法处理，请稍后再试。";}finally{_busy="";}Render();
    }
    void OpenPayment(string value){try{if(!Uri.TryCreate(value,UriKind.Absolute,out var uri)||uri.Scheme!="https")throw new InvalidDataException();System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri.AbsoluteUri){UseShellExecute=true});}catch{_error="付款页面未能打开，请点击重新打开。";Render();}}
    async Task Poll(){var id=_ticketId;var started=DateTimeOffset.UtcNow;while(!_disposed&&id==_ticketId&&DateTimeOffset.UtcNow-started<TimeSpan.FromMinutes(30)){try{_ticket=await Request("/api/agent/tickets/"+id);Render();if(_ticket.Text("state")!="pending")return;}catch(OperationCanceledException){return;}catch{}try{await Task.Delay(3000,_life.Token);}catch(OperationCanceledException){return;}}}
    async Task Finish(){var done=Phase=="done";_ticketId=_openUrl="";_ticket=null;_attemptKey="";if(done)await Load();else Render();}
}
