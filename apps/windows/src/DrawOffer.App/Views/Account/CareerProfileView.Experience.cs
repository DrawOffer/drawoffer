using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Account.AccountPage;

namespace DrawOffer.App.Views.Account;

public sealed partial class CareerProfileView
{
    JsonObject ExperienceCopy() => Experience?.DeepClone() as JsonObject ?? new() { ["schema_version"]=1,["extra_basics"]=new JsonObject(),["sections"]=new JsonArray(),["supplements"]=new JsonObject(),["records"]=new JsonObject() };
    FrameworkElement ExperienceRows()
    {
        var panel=VStack(18);var sections=Experience.Items("sections");
        if(sections.Count==0)panel.Children.Add(VStack(12,Sans("还没有读取简历。选一份简历，教育、实习、项目和技能会一起带进来。",13,Sub).Wrap(),new V3Button("选择简历",()=>_=SwitchResume(),V3Button.Kind.Dark)));
        foreach(var group in CareerProfileRules.Groups(Experience)){
            var rows=VStack(0,Sans(group.Label,11.5,Fnt2,Medium));
            foreach(var item in group.Items){var id=item.Entry.Display("id");if(_editing=="entry:"+id)rows.Children.Add(EntryEditor(item));else{
                var fields=item.Entry["fields"];var sub=string.Join(" · ",new[]{"职位","角色","专业","学历学位"}.Select(fields.Text).Where(x=>x.Length>0));var period=string.Join(" – ",new[]{"开始时间","结束时间"}.Select(fields.Text).Where(x=>x.Length>0));
                var extra=Experience?["supplements"]?[id] as JsonObject??new();var meta=extra.OrderBy(x=>x.Key,StringComparer.Ordinal).Where(x=>x.Value?.GetValue<string>().Length>0).Select(x=>SupplementLabel(x.Key)+" "+x.Value!.GetValue<string>()).ToList();if(item.Kind=="work"&&fields.Text("部门").Length>0)meta.Insert(0,fields.Text("部门"));if(item.Entry.Text("description").Length>0)meta.Add($"描述 {new System.Globalization.StringInfo(item.Entry.Text("description")).LengthInTextElements} 字");if(item.Kind=="work"&&fields.Text("部门").Length==0&&extra.Text("department").Length==0)meta.Add("部门未填");
                var content=VStack(4,Spread(HStack(10,Sans(CareerProfileRules.EntryTitle(item.Entry),14,Txt,Medium),Sans(sub,12.5,Sub)),Sans(period,12,Fnt2)),Sans(string.Join(" · ",meta),12,Fnt).Wrap());var button=new Button{Content=content,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,Padding=new Thickness(0,13,0,13),BorderThickness=new(0),Background=Brush(Clear)};button.Click+=(_,_)=>{_editing="entry:"+id;Render();};rows.Children.Add(button);
            }}panel.Children.Add(rows);
        }
        var hasSkills=Experience.Items("skills").Count>0;
        for(var i=0;i<sections.Count;i++){
            var index=i;var section=sections[i];if(!CareerProfileRules.TextKinds.Contains(section.Text("kind"))||(hasSkills&&section.Text("kind")=="skills"))continue;
            var title=section.Text("title") is {Length:>0} t?t:"技能";var text=TextSection(section);var key="text:"+index;
            if(_editing==key){var input=Input(text,title,100);input.AcceptsReturn=true;input.TextWrapping=TextWrapping.Wrap;panel.Children.Add(EditBox(title,input,()=>{var next=ExperienceCopy();var target=next["sections"]![index]!;target["lines"]=new JsonArray(input.Text.Split('\n').Where(x=>x.Trim().Length>0).Select(x=>(JsonNode?)JsonValue.Create(x)).ToArray());target["entries"]=new JsonArray();_=Save(new(){["experience"]=next});}));}
            else panel.Children.Add(ValueRow(title,text,()=>{_editing=key;Render();}));
        }
        var add=HStack(10,Sans("＋",13,Blue),Sans("添加一段",12.5,Sub));foreach(var (kind,intern,label) in new[]{("education",false,"教育"),("work",true,"实习"),("work",false,"工作"),("project",false,"项目"),("activity",false,"校园")})add.Children.Add(LinkButton(label,()=>AddEntry(kind,intern,label)));panel.Children.Add(add);return panel;
    }
    static string TextSection(JsonNode section) => string.Join("\n",section.Items("lines").Select(x=>x.GetValue<string>()).Concat(section.Items("entries").Select(entry=>string.Join("\n",new[]{string.Join(" | ",(entry["fields"] as JsonObject??new()).OrderBy(x=>x.Key,StringComparer.Ordinal).Select(x=>x.Value?.GetValue<string>()??"")),entry.Text("description")}.Where(x=>x.Length>0)))));
    string SupplementLabel(string key)=>_profile?["catalog"]?["fields"]?["profile.entry."+key].Text("label") is {Length:>0} label?label:key;
    void AddEntry(string kind,bool intern,string label)
    {
        if(_saving)return;var next=ExperienceCopy();var sections=next["sections"] as JsonArray??new();var section=sections.FirstOrDefault(x=>x.Text("kind")==kind);var id="e_"+Guid.NewGuid().ToString("N")[..16];var entry=new JsonObject{["id"]=id,["fields"]=new JsonObject(),["description"]="",["ambiguous"]=new JsonArray(),["intern"]=intern};
        if(section is null){section=new JsonObject{["id"]="",["kind"]=kind,["title"]=label+"经历",["lines"]=new JsonArray(),["entries"]=new JsonArray()};sections.Add(section);}((JsonArray)section["entries"]!).Add(entry);if(next["sections"] is null)next["sections"]=sections;_=Save(new(){["experience"]=next},"entry:"+id);
    }
    void ReplaceEntry(CareerProfileRules.Item item,JsonNode? entry,JsonObject? extra)
    {
        var next=ExperienceCopy();var id=item.Entry.Display("id");var section=next["sections"]![item.SectionIndex]!;section["entries"]=new JsonArray(section.Items("entries").Where(x=>entry is not null||x.Display("id")!=id).Select(x=>x.Display("id")==id?entry?.DeepClone():x.DeepClone()).ToArray());
        var supplements=next["supplements"] as JsonObject??new();if(entry is null||extra?.Count==0)supplements.Remove(id);else if(extra is not null)supplements[id]=extra.DeepClone();if(next["supplements"] is null)next["supplements"]=supplements;_=Save(new(){["experience"]=next});
    }
    FrameworkElement EntryEditor(CareerProfileRules.Item item)
    {
        var original=item.Entry["fields"] as JsonObject??new();var id=item.Entry.Display("id");var supplement=Experience?["supplements"]?[id] as JsonObject??new();var fields=new Dictionary<string,TextBox>();var extras=new Dictionary<string,TextBox>();var shape=CareerProfileRules.EntryKind(item.Kind);
        var keys=CareerProfileRules.EntryFields[shape].Concat(original.Select(x=>x.Key).Order(StringComparer.Ordinal)).Distinct().ToArray();var grid=new Grid{ColumnSpacing=12,RowSpacing=12};for(var c=0;c<3;c++)grid.ColumnDefinitions.Add(new(){Width=Star()});var position=0;
        void Field(string key,string label,string value,bool extra){var input=Input(value,label);if(extra)extras[key]=input;else fields[key]=input;var block=VStack(5,Sans(label+(extra&&value.Length==0?"  网申常问":""),11.5,Fnt,Medium),input);var row=position/3;while(grid.RowDefinitions.Count<=row)grid.RowDefinitions.Add(new(){Height=Auto});Grid.SetColumn(block,position%3);Grid.SetRow(block,row);grid.Children.Add(block);position++;}
        foreach(var key in keys)Field(key,key,original.Text(key),false);foreach(var key in CareerProfileRules.EntrySupplements[shape])Field(key,SupplementLabel(key),supplement.Text(key),true);
        var description=Input(item.Entry.Text("description"),"内容",80);description.AcceptsReturn=true;description.TextWrapping=TextWrapping.Wrap;
        void Remove()=>ReplaceEntry(item,null,null);
        void Done(){var clean=new JsonObject();foreach(var pair in fields)if(pair.Value.Text.Trim().Length>0)clean[pair.Key]=pair.Value.Text.Trim();var extra=(JsonObject)supplement.DeepClone();foreach(var pair in extras){if(pair.Value.Text.Trim().Length>0)extra[pair.Key]=pair.Value.Text.Trim();else extra.Remove(pair.Key);}var text=description.Text.Trim();if(clean.Count==0&&extra.Count==0&&text.Length==0){Remove();return;}var next=item.Entry.DeepClone();next["fields"]=clean;next["description"]=text;next["ambiguous"]=new JsonArray(item.Entry.Items("ambiguous").Where(x=>!clean.ContainsKey(x.GetValue<string>())).Select(x=>x.DeepClone()).ToArray());ReplaceEntry(item,next,extra);}
        return Fill(Hex(0xF7F7F5),10,child:VStack(12,grid,shape=="education"?null:VStack(5,Sans("内容",11.5,Fnt,Medium),description),Spread(Sans("只改这里，不影响简历",11.5,Fnt),HStack(14,LinkButton("删除这段",Remove),LinkButton("取消",()=>{if(original.Count==0&&item.Entry.Text("description").Length==0&&supplement.Count==0)Remove();else{_editing="";Render();}}),LinkButton("完成",Done))))).WithPadding(new(14,12,14,14)).Pad(0,4,0,4);
    }
    FrameworkElement SkillRows()
    {
        var skills=CareerProfileRules.Skills(Experience);
        if(_editing!="skills"){
            var panel=VStack(0);foreach(var (id,label) in CareerProfileRules.SkillLevels.Reverse().Concat(new[]{("unset","未标注")})){var names=skills.Where(x=>id=="unset"?x.Level is null:x.Level==id).Select(x=>x.Name).ToArray();if(names.Length>0)panel.Children.Add(ValueRow(label,string.Join("、",names),()=>{_editing="skills";Render();},panel.Children.Count==0));}if(panel.Children.Count==0)panel.Children.Add(ValueRow("技能","",()=>{_editing="skills";Render();},true));return panel;
        }
        var draft=skills.ToList();var rows=VStack(8);var adding=Input("","添加技能");adding.PlaceholderText="添加技能，用顿号分开，回车确定";
        void Paint(){rows.Children.Clear();for(var i=0;i<draft.Count;i++){var index=i;var skill=draft[i];var level=new V3Segmented<string>(CareerProfileRules.SkillLevels.Select(x=>(x.Id,x.Label)).Concat(new[]{("unset","未标注")}),skill.Level??"unset",fontSize:12);level.Changed+=value=>draft[index]=draft[index] with{Level=value=="unset"?null:value};rows.Children.Add(Spread(Sans(skill.Name,13.5),HStack(12,level,LinkButton("×",()=>{draft.RemoveAt(index);Paint();}))));}rows.Children.Add(adding);}
        void Add(){var known=draft.Select(x=>x.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);foreach(var name in adding.Text.Split(['、',',','，',';','；','/','\n']).Select(x=>x.Trim()))if(name.Length is >0 and <=60&&draft.Count<60&&known.Add(name))draft.Add(new(name,"familiar"));adding.Text="";Paint();}
        adding.KeyDown+=(_,e)=>{if(e.Key==Windows.System.VirtualKey.Enter){e.Handled=true;Add();}};Paint();return EditBox("技能",rows,()=>{Add();var next=ExperienceCopy();next["skills"]=new JsonArray(draft.Select(x=>(JsonNode?)new JsonObject{["name"]=x.Name,["level"]=x.Level}).ToArray());_=Save(new(){["experience"]=next});});
    }
}
