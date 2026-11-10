using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views.Account;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

internal sealed partial class PlansView
{
    V3Overlay? _support;
    JsonNode? _balance,_month,_mine;List<JsonNode>? _ledger;List<JsonNode> _rewards=[];
    string _direction="all",_cursor="",_creditsState="",_inviteState="",_copied="",_ledgerError="";int _ledgerGeneration;bool _more;
    static double N(JsonNode? node,string key)=>double.TryParse(node.Display(key),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out var value)&&double.IsFinite(value)?value:0;
    static string Credits(double value)=>BillingSummary.Credits(value.ToString(System.Globalization.CultureInfo.InvariantCulture));
    static string Day(string value)=>DateTimeOffset.TryParse(value,out var date)?date.ToBeijing().ToString("M 月 d 日"):"";
    static string Stamp(string value){if(!DateTimeOffset.TryParse(value,out var date))return "";date=date.ToBeijing();return date.Date==Beijing.Today?"今天 "+date.ToString("HH:mm"):date.ToString("MM-dd HH:mm");}
    FrameworkElement State(string message,Action retry)=>VStack(12,Sans(message,14,Sub),new V3Button("重试",retry));
    FrameworkElement Credits()
    {
        if(_creditsState.Length==0)return Sans("正在加载…",14,Sub);
        if(_creditsState=="error")return State("暂时无法读取积分明细，请重试。",()=>_=LoadCredits());
        if(_balance is null)return Sans("正在加载…",14,Sub);
        var balances=_balance["balances"];var member=_balance.Text("tier")!="none";var extra=N(balances?["pack"],"remaining")+N(balances?["gift"],"remaining");var period=balances?[member?"membership":"freeMonthly"];var total=N(period,"total");if(member&&period?["total"] is null)total=N(period,"remaining");var used=Math.Max(0,total-N(period,"remaining"));var all=total+extra;var share=all>0?Math.Clamp(used/all,0,1):0;var percent=(int)Math.Round(share*100,MidpointRounding.AwayFromZero);var warn=share>=.8;
        var bar=new Grid{Height=10,Background=Brush(Hex(0xEEEEEA)),CornerRadius=new(5)};var fill=Fill(warn?Hex(0xD47C28):Hex(0x2B2B28),5,height:10).Align(HorizontalAlignment.Left);bar.Children.Add(fill);bar.SizeChanged+=(_,_)=>fill.Width=Math.Max(10,bar.ActualWidth*share);bar.Tip("已用积分 "+percent+"%");
        var reset=member?(period.Text("expireTime").Length>0?Day(period.Text("expireTime"))+"到期，未用完的清零":""):Day(period.Text("resetTime"))+"重置为 "+Credits(N(period,"total"));
        var summary=VStack(14,Spread(VStack(4,Sans(member?"会员积分":"本月免费积分",13,Sub),HStack(8,Label(BillingSummary.Credits(_balance.Display("available")),40,Txt,Semibold),Sans("积分可用",14,Sub))),Sans($"已用 {percent}%",14,warn?Hex(0xD47C28):Txt,Medium)),bar,Spread(Sans($"{(member?"本期":"本月")}已用 {Credits(used)} / {Credits(all)}",12.5,Sub),Sans(reset,12.5,Sub)),N(_balance,"overdraft")>0?Sans($"含透支 {Credits(N(_balance,"overdraft"))} 积分，下次获得积分时先抵扣",12,Fnt):!member&&extra==0?Sans("免费积分只能用基础模型；开通会员可用全部模型",12,Fnt):null,Divider(Cl).Top(10));
        var filters=HStack(4);foreach(var (id,label) in new[]{("all","全部"),("use","使用"),("gain","获得")})filters.Children.Add(AccountPage.LinkButton(label,()=>{if(_direction==id)return;_direction=id;_=LoadCredits();}));
        var header=Spread(HStack(16,Sans("积分变动",15,Txt,Medium),filters),Sans(_month is null?"":$"本月使用 {BillingSummary.Credits(_month.Display("used"))} · 获得 {BillingSummary.Credits(_month.Display("gained"))}",12,Fnt)).Top(20);
        var rows=VStack(0);if(_ledger is null)rows.Children.Add(Sans("正在加载…",13,Fnt));else if(_ledger.Count==0)rows.Children.Add(Sans("还没有积分变动。",13,Fnt).Top(12));else foreach(var row in _ledger){var points=N(row,"points");var muted=row.Text("entryType") is "expire" or "void";rows.Children.Add(new Border{Child=Columns(16,(Star(),Sans(row.Text("title"),14,muted?Fnt:Txt)),(Auto,Label(Stamp(row.Text("occurTime")),12.5,Fnt)),(Px(72),Label(points>0?"+"+Credits(points):Credits(points).Replace("-","−"),14,muted?Fnt:points>0?Hex(0x2F9A5B):Txt,Semibold).Align(HorizontalAlignment.Right))),Padding=new(0,12,0,12),BorderBrush=Brush(Cl),BorderThickness=new(0,rows.Children.Count==0?0:1,0,0)});}
        if(_ledgerError.Length>0)rows.Children.Add(Sans(_ledgerError,12.5,Red).Wrap().Top(8));
        if(_cursor.Length>0)rows.Children.Add(new V3Button(_more?"正在加载…":"加载更早的记录",()=>_=MoreCredits(),V3Button.Kind.Text){Enabled=!_more});
        var grid=new Grid();grid.RowDefinitions.Add(new(){Height=Auto});grid.RowDefinitions.Add(new(){Height=Star()});grid.Children.Add(VStack(6,summary,header));var scroll=new ScrollViewer{Content=rows};Grid.SetRow(scroll,1);grid.Children.Add(scroll);return grid;
    }
    async Task<JsonNode> Ledger(string cursor,string direction){var query=new Dictionary<string,string>{["limit"]="20"};if(cursor.Length>0)query["cursor"]=cursor;if(direction!="all")query["direction"]=direction;return await Request("/api/billing/ledger",query:query);}
    async Task LoadCredits(){var generation=++_ledgerGeneration;var direction=_direction;_creditsState="loading";_ledgerError="";_ledger=null;_cursor="";_more=false;Render();try{var summary=Request("/api/billing/summary");var page=Ledger("",direction);await Task.WhenAll(summary,page);if(generation!=_ledgerGeneration)return;_balance=summary.Result;_ledger=page.Result.Items("items");_month=page.Result["month"]?.DeepClone();_cursor=page.Result.Text("nextCursor");_creditsState="ready";}catch(OperationCanceledException){return;}catch{if(generation!=_ledgerGeneration)return;_creditsState="error";}Render();}
    async Task MoreCredits(){if(_more||_cursor.Length==0)return;var generation=_ledgerGeneration;_more=true;_ledgerError="";Render();try{var page=await Ledger(_cursor,_direction);if(generation!=_ledgerGeneration)return;_ledger?.AddRange(page.Items("items"));_cursor=page.Text("nextCursor");}catch(OperationCanceledException){return;}catch{if(generation==_ledgerGeneration)_ledgerError="积分记录加载失败，请重试。";}finally{if(generation==_ledgerGeneration)_more=false;}Render();}
    FrameworkElement Invite()
    {
        if(_inviteState.Length==0)return Sans("正在加载…",14,Sub);if(_inviteState=="error")return State("暂时无法读取邀请信息，请重试。",()=>_=LoadInvite());if(_mine is null)return Sans("正在加载…",14,Sub);
        var rewards=_mine.Items("rewards");var coupon=InviteCoupon();
        var rewardColumns=new Grid{ColumnSpacing=16};foreach(var reward in rewards){rewardColumns.ColumnDefinitions.Add(new(){Width=Star()});var block=VStack(4,Sans(reward.Text("title"),12,Sub),Label(reward.Text("reward"),26,Blue,Semibold),Sans("好友付 "+reward.Text("price"),11.5,Fnt));Grid.SetColumn(block,rewardColumns.Children.Count);rewardColumns.Children.Add(block);}
        var rewardCard=Card(VStack(14,Sans("好友每开通一次会员，你得到现金返现",13,Txt,Medium),rewardColumns,Sans("返现按好友开通的会员档位计算，核实后用微信或支付宝转给你",11.5,Fnt).Wrap()),16,new Thickness(24,20,24,20)).Frame(height:184);
        var top=Columns(16,(Px(400),coupon),(Star(),rewardCard));var stats=HStack(22,Sans("待结算",12,Fnt),Label("¥"+N(_mine,"pendingAmount").ToString("F2"),18,Hex(0xB8661A),Semibold),Sans("已到账",12,Fnt),Label("¥"+N(_mine,"paidAmount").ToString("F2"),18,Txt,Semibold),Sans("已邀请 "+_mine.Display("invitedCount")+" 人",12,Fnt));
        var claim=Fill(Field,10,child:Spread(Sans("领取返现  ① 截图这份记录 → ② 添加客服微信并发送截图 → ③ 核实后转账",12.5,Sub).Wrap(),new V3Button("查看客服微信",SupportQr,height:28,small:true))).WithPadding(new(14,8,10,8));
        var rows=VStack(0);if(_rewards.Count==0){
            var example=VStack(0);var index=0;foreach(var reward in rewards.Take(4)){
                var avatar=new Microsoft.UI.Xaml.Shapes.Ellipse{Width=28,Height=28,Stroke=Brush(Hex(0xC9C9C3)),StrokeDashArray=new DoubleCollection{3,2}};
                var row=Columns(12,(Px(28),avatar),(Star(),Sans($"好友 {(char)('A'+index)} 开通{reward.Text("title")}",13.5,Fnt)),(Px(40),Fill(Hex(0xF1F1EE),8,40,16)),(Auto,Label("+"+reward.Text("reward"),13.5,Blue,Semibold))).Pad(0,11,0,11);example.Children.Add(new Border{Child=row,BorderBrush=Brush(Cl),BorderThickness=new(0,index>0?1:0,0,0)});index++;
            }
            var fade=new Grid{IsHitTestVisible=false,Background=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(0,1),GradientStops={new GradientStop{Color=Alpha(White,0),Offset=.2},new GradientStop{Color=White,Offset=.85}}}};
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(example,Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            var empty=Layer(Layer(example,fade),VStack(6,Sans("还没有好友用你的邀请码开通会员",14,Txt,Medium),Sans("把邀请文案发到同学群或求职群，好友开通后返现会记在这里",12.5,Sub).Wrap(),new V3Button(_copied=="text"?"已复制":"复制邀请文案",()=>CopyInvite("text"),height:28,small:true)).Pad(0,110,0,16));empty.MinHeight=220;rows.Children.Add(empty);
        }
        else foreach(var row in _rewards){var status=row.Text("status");var label=status=="pending"?"待结算":status=="paid"?"已到账":"已退款";var tone=status=="pending"?Hex(0xB8661A):status=="paid"?Hex(0x2E7D4F):Fnt;var date=DateTimeOffset.TryParse(row.Text("createTime"),out var time)?time.ToBeijing().ToString("M-dd"):"";rows.Children.Add(new Border{Child=Columns(12,(Px(28),AccountPage.Avatar(null,System.Globalization.StringInfo.GetNextTextElement(row.Text("buyerLabel") is {Length:>0} buyer?buyer:"?"),28)),(Star(),Sans(row.Text("buyerLabel")+" 开通"+row.Text("planTitle"),13.5,status=="void"?Fnt:Txt)),(Auto,Label(date,12,Fnt)),(Auto,Fill(status=="pending"?Hex(0xFBF0E2):status=="paid"?Hex(0xE7F3EC):Hex(0xF1F1EE),10,child:Sans(label,11.5,tone,Medium)).WithPadding(new(8,1,8,1))),(Px(64),RewardAmount(row))),Padding=new(0,11,0,11),BorderBrush=Brush(Cl),BorderThickness=new(0,rows.Children.Count>0?1:0,0,0)});}
        var ledger=new Grid{RowSpacing=12};ledger.RowDefinitions.Add(new(){Height=Auto});ledger.RowDefinitions.Add(new(){Height=Auto});ledger.RowDefinitions.Add(new(){Height=Star()});ledger.Children.Add(Spread(HStack(10,Sans("我的邀请记录",15,Txt,Medium),Sans(_mine.Text("code"),12,Sub)),stats));Grid.SetRow(claim,1);ledger.Children.Add(claim);var scroll=new ScrollViewer{Content=rows};Grid.SetRow(scroll,2);ledger.Children.Add(scroll);
        var grid=new Grid{RowSpacing=16};grid.RowDefinitions.Add(new(){Height=Auto});grid.RowDefinitions.Add(new(){Height=Star()});grid.Children.Add(top);var card=Card(ledger,16,new Thickness(24,18,24,8));Grid.SetRow(card,1);grid.Children.Add(card);return grid;
    }
    FrameworkElement InviteCoupon()
    {
        var code=Label(_mine.Text("code"),30,Txt,Semibold).Frame(height:38);code.CharacterSpacing=100;
        var content=Columns(0,(Px(136),VStack(2,Sans("好友开通会员",12,Blue).Frame(height:22),HStack(2,Sans("立减",14,Blue,Medium),Label("¥"+_mine.Display("discountAmount"),44,Blue,Semibold).Frame(height:52))).Align(HorizontalAlignment.Center,VerticalAlignment.Center)),(Star(),VStack(6,Sans("我的邀请码",12,Sub).Frame(height:22),code,HStack(8,new V3Button(_copied=="code"?"已复制":"复制邀请码",()=>CopyInvite("code"),V3Button.Kind.Dark,height:28,small:true),new V3Button(_copied=="text"?"已复制":"复制邀请文案",()=>CopyInvite("text"),height:28,small:true)).Top(10)).Align(v:VerticalAlignment.Center).Pad(24,0,20,0)));
        var grid=new Grid{Width=400,Height=184,Clip=new RectangleGeometry{Rect=new(0,0,400,184)}};grid.Children.Add(Fill(Hex(0xEEF3FD),16,400,184,content));
        var decorations=new Canvas{IsHitTestVisible=false};decorations.Children.Add(new Microsoft.UI.Xaml.Shapes.Line{X1=136,X2=136,Y1=16,Y2=168,Stroke=Brush(Alpha(Blue,.35)),StrokeThickness=1,StrokeDashArray=new DoubleCollection{4,3}});
        foreach(var top in new[]{-11d,173}){var hole=new Microsoft.UI.Xaml.Shapes.Ellipse{Width=22,Height=22,Fill=Brush(White)};Canvas.SetLeft(hole,125);Canvas.SetTop(hole,top);decorations.Children.Add(hole);}grid.Children.Add(decorations);return grid.Tip("邀请券");
    }
    async Task LoadInvite(){_inviteState="loading";Render();try{var mine=Request("/api/billing/invite-code");var list=Request("/api/billing/invite-rewards",query:new(){["limit"]="20"});await Task.WhenAll(mine,list);_mine=mine.Result;_rewards=list.Result.Items("items");_inviteState="ready";}catch(OperationCanceledException){return;}catch{_inviteState="error";}Render();}
    void CopyInvite(string kind){if(_mine is null)return;var origin=App.Session.Api is HttpApiClient client?client.Coordinator.Origin.AbsoluteUri:"";var text=kind=="code"?_mine.Text("code"):$"我在用 DrawOffer 准备求职。开通会员时填写我的邀请码 {_mine.Text("code")}，立减 ¥{_mine.Display("discountAmount")}：{origin}";var package=new Windows.ApplicationModel.DataTransfer.DataPackage();package.SetText(text);Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);_copied=kind;Render();_=Reset();async Task Reset(){try{await Task.Delay(1600,_life.Token);if(_copied==kind){_copied="";Render();}}catch(OperationCanceledException){}}}
    static TextBlock Strike(TextBlock text){text.TextDecorations=Windows.UI.Text.TextDecorations.Strikethrough;return text;}
    static TextBlock RewardAmount(JsonNode row){var text=Label("¥"+N(row,"amount").ToString("F2"),13.5,row.Text("status")=="void"?Fnt:Txt,Medium);return row.Text("status")=="void"?Strike(text):text;}
    void SupportQr()
    {
        if(_support?.IsOpen==true)return;var origin=App.Session.Api is HttpApiClient client?client.Coordinator.Origin:null;if(origin is null)return;
        var hint=Sans("正在加载…",12.5,Fnt).Wrap().Align(HorizontalAlignment.Center,VerticalAlignment.Center);var image=new Image{Width=280,Height=280,Stretch=Stretch.Uniform};image.ImageFailed+=(_,_)=>hint.Text="二维码暂时无法显示，请稍后再试";image.ImageOpened+=(_,_)=>hint.Visibility=Visibility.Collapsed;image.Source=new BitmapImage(new Uri(origin,"/support-wechat-qr.png"));
        var picture=Layer(hint,image).Frame(width:280,height:280);_support=V3Overlay.Show(XamlRoot,close=>V3Dialog.Frame(Layer(VStack(10,Sans("添加客服微信",20,Txt,Medium),Sans("用微信扫码添加，发送邀请记录截图",14,Fnt),picture,Sans("核实后用微信或支付宝把返现转给你",14,Fnt)).Pad(40,32,40,28),V3Dialog.CloseButton(close).Align(HorizontalAlignment.Right,VerticalAlignment.Top).Pad(0,16,16,0)),400));
    }
}
