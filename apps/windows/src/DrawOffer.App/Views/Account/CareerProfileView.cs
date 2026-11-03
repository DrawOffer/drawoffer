using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Account.AccountPage;

namespace DrawOffer.App.Views.Account;

/// <summary>Mac CareerProfileView：只读行、就地编辑与独立的经历副本。</summary>
public sealed partial class CareerProfileView : Grid
{
    readonly AccountPage _owner;
    readonly Action _back;
    readonly ContentControl _form=new(){HorizontalContentAlignment=HorizontalAlignment.Stretch,VerticalContentAlignment=VerticalAlignment.Stretch};
    JsonNode? _profile,_intent;
    bool _failed,_saving,_more,_disposed;
    string _editing="";
    V3Overlay? _overlay;
    JsonNode? Experience => _profile?["experience"];
    public CareerProfileView(AccountPage owner,Action back)
    {
        _owner=owner;_back=back;Background=Brush(White);Loaded+=async(_,_)=>await Load();Unloaded+=(_,_)=>{_disposed=true;_overlay?.Close();};Render();
    }
    async Task Load()
    {
        try{var profile=_owner.Request("/api/account/career-profile");var intent=_owner.Request("/api/account/user-profile");await Task.WhenAll(profile,intent);if(_disposed)return;_profile=profile.Result;_intent=intent.Result;_failed=false;}
        catch(OperationCanceledException){return;}catch{if(_disposed)return;_failed=true;}Render();
    }
    async Task<bool> Save(JsonObject change,string next="")
    {
        if(_saving||_disposed||_profile is null)return false;var saved=false;_saving=true;_form.IsEnabled=false;
        try{change["base_lock_version"]=_profile["lock_version"]?.DeepClone()??JsonValue.Create(1);var value=await _owner.Request("/api/account/career-profile","PUT",change);if(_disposed)return false;_profile=value;_editing=next;saved=true;return true;}
        catch(OperationCanceledException){return false;}catch(Exception ex){if(!_disposed){_owner.Toast(Explain(ex,"请检查填写内容后重试。"),true);if(ex is ApiException {Code:"USER_PROFILE_VERSION_CONFLICT"})await Load();}return false;}
        finally{_saving=false;_form.IsEnabled=true;if(!_disposed&&saved)Render();}
    }
    async Task SaveIntent(JsonObject change)
    {
        if(_saving||_disposed)return;var saved=false;_saving=true;_form.IsEnabled=false;
        try{var latest=(JsonObject)await _owner.Request("/api/account/user-profile");var version=latest["lock_version"]?.DeepClone()??JsonValue.Create(1);latest.Remove("lock_version");latest.Remove("created_at");latest.Remove("updated_at");foreach(var pair in change)latest[pair.Key]=pair.Value?.DeepClone();latest["base_lock_version"]=version;_intent=await _owner.Request("/api/account/user-profile","PUT",latest);_editing="";saved=true;}
        catch(OperationCanceledException){}catch(Exception ex){if(!_disposed){_owner.Toast(Explain(ex),true);if(ex is ApiException {Code:"USER_PROFILE_VERSION_CONFLICT"})await Load();}}
        finally{_saving=false;_form.IsEnabled=true;if(!_disposed&&saved)Render();}
    }
    void Render()
    {
        if(_disposed)return;Children.Clear();
        var body=VStack(0,HStack(12,LinkButton("← 账号",_back),Sans("/",16,Fnt),Sans("求职资料",16)).Pad(0,0,0,20));
        if(_failed&&_profile is null)body.Children.Add(VStack(12,Serif("暂时无法读取求职资料",18),new V3Button("重新加载",()=>_=Load())).Top(40));
        else{
            var missing=_profile is null?[]:CareerProfileRules.Missing(_profile);
            var progress=missing.Length==0?Sans("网申常问的信息都填好了",12,Fnt):(UIElement)HStack(4,Sans("网申常问的信息",12,Fnt),Sans($"还差 {missing.Length} 项",12,Orange,Medium),LinkButton("去补",()=>{_editing=missing[0]=="id_number"?"id":missing[0];Render();}));
            body.Children.Add(VStack(0,Spread(VStack(6,Serif("求职资料",28).Frame(height:36),Sans("网申插件和 AI 都只用这一份。点任意一行就能修改，改完自动保存。",14,Sub).Wrap().LineHeight(22)),progress,24,VerticalAlignment.Bottom),Divider().Top(36)));
            if(_profile is null||_intent is null)body.Children.Add(Sans("正在加载求职资料…",13,Fnt).Top(80));
            else{
                body.Children.Add(Section("基本信息",null,PersonalRows(CareerProfileRules.Basic.Concat(CareerProfileRules.Links))));
                body.Children.Add(Section("身份与证件","网申常问，填一次所有公司通用",VStack(0,Identity(),PersonalRows(CareerProfileRules.Identity))));
                body.Children.Add(Section("求职意向","AI 出题和网申都会用",IntentRows()));
                var title=_profile["experience_resume"].Text("title");body.Children.Add(Section("经历",title.Length>0?$"读自《{title}》，改简历不会自动同步。":"从一份简历读进来，读进来后可以直接改。",ExperienceRows(),(Experience.Items("sections").Count==0?"选择简历":"切换简历",()=>_=SwitchResume())));
                body.Children.Add(Section("技能","写简历、模拟面试都按熟练度来；读简历时一起带进来",SkillRows()));
                var more=CareerProfileRules.MoreRows(_profile);body.Children.Add(Section("更多","偶尔会问",_more?PersonalRows(more):ValueRow($"其他 {more.Length} 项",$"身高、体重、微信、紧急联系人… 已填 {more.Count(x=>_profile["personal"].Text(x.Key).Length>0)} 项",()=>{_more=true;Render();},true)));
            }
        }
        _form.Content=new ScrollViewer {Content=new Border {Child=body,MaxWidth=948,Padding=new Thickness(24,51,24,64),HorizontalAlignment=HorizontalAlignment.Stretch},HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Children.Add(_form);
    }
    FrameworkElement Section(string title,string? description,UIElement content,(string Label,Action Action)? action=null)
    {
        var left=VStack(6,Sans(title,14,Txt,Bold).Frame(height:22),description is null?null:Sans(description,12,Fnt).Wrap().LineHeight(19),action is {} a?LinkButton(a.Label,a.Action):null);
        return VStack(0,Columns(40,(Px(160),left),(Star(),content)).Pad(0,28,0,28),Divider());
    }
    static FrameworkElement ValueRow(string label,string value,Action edit,bool first=false)
    {
        var row=Columns(16,(Px(112),Sans(label,13,Fnt).Wrap().LineHeight(22)),(Star(),Sans(value.Length==0?"未填":value,14,value.Length==0?Orange:Txt).Wrap().LineHeight(22)),(Auto,Sans(value.Length==0?"填写":"›",12.5,value.Length==0?Blue:Hex(0xC2C2BE))));
        var button=new Button {Content=row,Padding=new Thickness(0,12,0,12),HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,Background=Brush(Clear),BorderThickness=new(0),MinHeight=46};button.Click+=(_,_)=>edit();
        return new Border {Child=button,BorderBrush=Brush(Hex(0xF2F1EE)),BorderThickness=new(0,first?0:1,0,0)};
    }
    FrameworkElement EditBox(string label,UIElement fields,Action done,string? hint=null,UIElement? extra=null,Action? cancel=null)
    {
        var actions=HStack(14,extra,LinkButton("取消",()=>{if(cancel is not null)cancel();else{_editing="";Render();}}),LinkButton(_saving?"保存中…":"完成",()=>{if(!_saving)done();}));
        return Fill(Hex(0xF7F7F5),10,child:VStack(10,Columns(16,(Px(98),Sans(label,13,Fnt)),(Star(),fields)),Spread(Sans(hint??"",11.5,Fnt).Wrap(),actions,14))).WithPadding(new(14,12,14,14)).Pad(0,4,0,4);
    }
    FrameworkElement PersonalRows(IEnumerable<CareerProfileRules.Row> rows)
    {
        var panel=VStack(0);var first=true;
        foreach(var row in rows){var key=row.Key;var value=_profile?["personal"].Text(key)??"";var label=_profile?["catalog"]?["fields"]?["profile.personal."+key].Text("label");if(string.IsNullOrEmpty(label))label=row.Label;
            if(_editing==key){var input=Input(value,label);string draft=value;UIElement field=input;if(row.Options is {} options){var segment=new V3Segmented<string>(options.Select(x=>(x,x)),value);segment.Changed+=next=>draft=next;field=segment;}else input.TextChanged+=(_,_)=>draft=input.Text;
                void Done(){var personal=(_profile?["personal"] as JsonObject)?.DeepClone() as JsonObject??new();if(draft.Trim().Length==0)personal.Remove(key);else personal[key]=draft.Trim();_=Save(new(){["personal"]=personal});}
                input.KeyDown+=(_,e)=>{if(e.Key==Windows.System.VirtualKey.Enter)Done();else if(e.Key==Windows.System.VirtualKey.Escape){_editing="";Render();}};panel.Children.Add(EditBox(label,field,Done,row.Hint));
            }else panel.Children.Add(ValueRow(label,value,()=>{if(!_saving){_editing=key;Render();}},first));first=false;
        }return panel;
    }
    FrameworkElement Identity()
    {
        if(_editing!="id")return ValueRow("证件",_profile.Bool("has_id_number")?_profile.Text("id_type")+" · "+_profile.Text("id_number_masked")+"\n加密保存，只在网申时填进表单，不发给 AI":"",()=>{_editing="id";Render();},true);
        var types=_profile?["catalog"].Items("id_types").Select(x=>x.GetValue<string>()).ToArray()??[];var combo=new ComboBox {ItemsSource=types,SelectedItem=_profile.Text("id_type"),Width=180,Height=34,MinHeight=0};if(combo.SelectedIndex<0&&types.Length>0)combo.SelectedIndex=0;
        var number=Input("","证件号码");number.PlaceholderText=_profile.Bool("has_id_number")?"输入新的号码替换 "+_profile.Text("id_number_masked"):"证件号码";
        return EditBox("证件",Columns(8,(Auto,combo),(Star(),number)),()=>{if(number.Text.Trim().Length==0){_editing="";Render();}else Consent(combo.SelectedItem as string??"",number.Text.Trim());},"加密保存，只在网申时填进表单，不发给 AI",_profile.Bool("has_id_number")?LinkButton("删除证件号码",()=>_=Save(new(){["id_number"]=""})):null);
    }
    void Consent(string type,string number)
    {
        var agreed=new CheckBox {Content="我同意 DrawOffer 按以上方式保存我的证件号码",FontSize=13};var version=_profile?["catalog"].Text("consent_version")??"";var busy=false;
        _overlay=V3Overlay.Show(XamlRoot,close=>{
            var error=Sans("",13,Red).Wrap();var cancel=new V3Button("暂不保存",()=>{if(!busy)close();},height:36);V3Button? submit=null;submit=new V3Button("同意并保存",()=>_=Accept(),V3Button.Kind.Dark,height:36){Enabled=false};agreed.Click+=(_,_)=>submit.Enabled=agreed.IsChecked==true&&!busy;
            async Task Accept(){if(busy||agreed.IsChecked!=true)return;busy=true;cancel.Enabled=submit!.Enabled=false;submit.Title="保存中…";if(await Save(new(){["id_type"]=type,["id_number"]=number,["id_number_consent"]=new JsonObject{["accepted"]=true,["version"]=version}}))close();else{busy=false;cancel.Enabled=true;submit.Enabled=agreed.IsChecked==true;submit.Title="同意并保存";error.Text="没有保存，请检查填写内容后重试。";}}
            return V3Dialog.Make(VStack(16,V3DialogHead.Make("保存证件号码","证件号码属于敏感个人信息，保存前需要你单独同意。"),Notes("只在你使用网申插件时，填进招聘网站的表单","加密保存；页面上只显示前 6 位和后 4 位","不发给 AI，不用于其他任何用途","随时可以在「求职资料」里删除，删除后不再保留"),agreed, Sans("说明版本 "+version,11.5,Fnt),error),[cancel,submit],()=>{if(!busy)close();},460,closable:false);
        },dismissible:false);
    }
    FrameworkElement IntentRows()
    {
        var panel=VStack(0);var cities=string.Join("、",_intent.Items("candidate_cities").Select(x=>x.GetValue<string>()));var kinds=_intent.Items("employment_types").Select(x=>x.GetValue<string>()).ToHashSet();
        foreach(var (key,label,value) in new[]{("intent.cities","期望城市",cities),("intent.salary","期望薪资",CareerProfileRules.SalaryText(_intent!)),("intent.kinds","工作性质",string.Join("、",kinds.Select(x=>x=="internship"?"实习":"全职")))}){
            if(_editing!=key){panel.Children.Add(ValueRow(label,value,()=>{_editing=key;Render();},panel.Children.Count==0));continue;}
            var input=Input(cities,label);input.PlaceholderText="用顿号分开，例如 杭州、上海";var low=Input(_intent.Number("salary_min") is {} l?Math.Round(l/1000,MidpointRounding.AwayFromZero).ToString():"","最低");low.Width=96;var high=Input(_intent.Number("salary_max") is {} h?Math.Round(h/1000,MidpointRounding.AwayFromZero).ToString():"","最高");high.Width=96;
            var choices=HStack(8);foreach(var (id,text) in new[]{("internship","实习"),("full_time","全职")}){var check=new CheckBox {Content=text,IsChecked=kinds.Contains(id)};check.Click+=(_,_)=>{if(check.IsChecked==true)kinds.Add(id);else kinds.Remove(id);};choices.Children.Add(check);}
            void Done(){JsonObject change;if(key=="intent.cities")change=new(){["candidate_cities"]=new JsonArray(input.Text.Split(['、',',','，',' ','\n'],StringSplitOptions.RemoveEmptyEntries).Select(x=>x.Trim()).Where(x=>x.Length>0).Take(20).Select(x=>(JsonNode?)JsonValue.Create(x)).ToArray())};else if(key=="intent.kinds")change=new(){["employment_types"]=new JsonArray(kinds.Select(x=>(JsonNode?)JsonValue.Create(x)).ToArray())};else{double? min=double.TryParse(low.Text,out var a)&&double.IsFinite(a)&&a>=0?a*1000:null;double? max=double.TryParse(high.Text,out var b)&&double.IsFinite(b)&&b>=0?b*1000:null;if(min is not null&&max<min)max=min;var has=min is not null||max is not null;change=new(){["salary_min"]=min,["salary_max"]=max,["salary_currency"]=has?"CNY":null,["salary_period"]=has?"month":null};}_=SaveIntent(change);}
            panel.Children.Add(EditBox(label,key=="intent.cities"?input:key=="intent.salary"?HStack(8,low,Sans("–",13,Sub),high,Sans("K / 月",13,Sub)):choices,Done));
        }return panel;
    }
    async Task SwitchResume()
    {
        if(_saving)return;var list=VStack(0,Sans("正在读取简历…",11.5,Fnt));var choices=new ContentControl{Content=list,HorizontalContentAlignment=HorizontalAlignment.Stretch};string choice="";var current=_profile?["experience_resume"].Display("id")??"";var hasExperience=Experience.Items("sections").Count>0;var submitTitle=hasExperience?"换成这份":"读取";var busy=false;var error=Sans("",13,Red).Wrap();V3Button? submit=null;
        _overlay=V3Overlay.Show(XamlRoot,close=>{var cancel=new V3Button("取消",()=>{if(!busy)close();},height:36);submit=new V3Button(submitTitle,()=>_=Read(),V3Button.Kind.Dark,height:36){Enabled=false};async Task Read(){if(busy||choice.Length==0||_profile is null)return;busy=true;choices.IsEnabled=false;cancel.Enabled=submit!.Enabled=false;submit.Title="读取中…";error.Text="";try{var value=await _owner.Request("/api/account/career-profile/read-resume","POST",new JsonObject{["base_lock_version"]=_profile["lock_version"]?.DeepClone()??JsonValue.Create(1),["resume_id"]=choice});if(_disposed)return;_profile=value;_editing="";close();Render();_owner.Toast("经历已读入");}catch(OperationCanceledException){}catch(Exception ex){error.Text=Explain(ex);if(ex is ApiException{Code:"USER_PROFILE_VERSION_CONFLICT"})await Load();}finally{busy=false;choices.IsEnabled=true;cancel.Enabled=true;submit.Enabled=choice.Length>0;submit.Title=submitTitle;}}
            return V3Dialog.Make(VStack(16,V3DialogHead.Make("从哪份简历读取经历","只换教育、实习、项目、奖项和技能；个人信息和求职意向不变。"),new ScrollViewer{Content=choices,MaxHeight=320},hasExperience?Notes("同一所学校、同一家公司下补过的 GPA、部门等会保留","新简历里没有的经历会被移除，这里只保存一份","不用 AI，几秒完成；读进来后照样可以改"):null,error),[cancel,submit],()=>{if(!busy)close();},460,closable:false);},dismissible:false);
        var overlay=_overlay;
        try{var result=await _owner.Request("/api/resumes");if(_disposed||overlay?.IsOpen!=true||overlay!=_overlay)return;var resumes=result.Items("resumes");list.Children.Clear();if(resumes.Count==0)list.Children.Add(Sans("还没有简历，先去「我的简历」新建一份。",11.5,Fnt));choice=(resumes.FirstOrDefault(x=>x.Display("id")!=current)??resumes.FirstOrDefault()).Display("id");foreach(var resume in resumes){var id=resume.Display("id");var radio=new RadioButton{Content=resume.Text("title")+(id==current?" · 正在使用":""),GroupName="career-resume",IsChecked=id==choice,Padding=new Thickness(14,12,14,12)};radio.Checked+=(_,_)=>choice=id;list.Children.Add(radio);}submit!.Enabled=choice.Length>0;}
        catch(OperationCanceledException){}catch{if(!_disposed&&overlay==_overlay&&overlay?.IsOpen==true){list.Children.Clear();list.Children.Add(VStack(12,Sans("暂时无法读取简历，请重试。",13,Sub),new V3Button("重新加载",()=>{_overlay?.Close();_=SwitchResume();})));}}
    }
}
