using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

public sealed partial class AccountPage
{
    void ContactEmail()
    {
        var original = User.Text("contact_email"); var input = Input(original,"邮箱地址",40); input.PlaceholderText="you@example.com";
        ShowForm("联系邮箱", "用于联系信息；保存后不会发送验证邮件或通知。", VStack(24, EmailArt(original), VStack(5,Sans("邮箱地址",14,Sub,Medium),input), Notes("留空即可清除联系邮箱。")),520,async () => {
            var email=input.Text.Trim(); if (email.Length > 0 && !Regex.IsMatch(email,@"^[^\s@]+@[^\s@]+\.[^\s@]+$")) throw new InvalidOperationException("请输入有效的邮箱地址。");
            var result=await Request("/api/account/contact-email","PUT",new JsonObject {["email"]=email.Length==0?null:email});
            var user=User!.DeepClone(); user["contact_email"]=result["contact_email"]?.DeepClone(); ApplyUser(user); Toast("联系邮箱已保存");
        });
    }
    void Logout()
    {
        var busy=false; var stamp=Stamp;
        _overlay=V3Overlay.Show(XamlRoot,close => {
            var cancel=new V3Button("取消",()=>{if(!busy)close();},height:40,fill:true);
            V3Button? confirm=null; confirm=new V3Button("退出登录",()=>_=Exit(),V3Button.Kind.Dark,height:40,fill:true);
            async Task Exit(){if(busy||stamp!=Stamp)return;busy=true;cancel.Enabled=confirm!.Enabled=false;confirm.Title="正在退出…";await App.Session.SignOutCommand.ExecuteAsync(null);close();}
            var body=VStack(0,LogoutArt(),Sans("确认退出登录？",20,Txt,Semibold).Align(HorizontalAlignment.Center).Top(20),Sans("退出后需要重新登录。",14,Sub).Align(HorizontalAlignment.Center).Top(6),Notes(_profile?["current_session"].Text("device_label")??"","其他设备上的登录不受影响").Top(11),Columns(12,(Star(),cancel),(Star(),confirm)).Top(32));
            return V3Dialog.Frame(new Border {Child=body,Padding=new Thickness(24)},420);
        },dismissible:false);
    }
    void ShowForm(string title,string subtitle,UIElement fields,double width,Func<Task> save,string submit="保存",Func<bool>? allowed=null)
    {
        var stamp=Stamp;var busy=false;
        _overlay=V3Overlay.Show(XamlRoot,close=>{
            var form=new ContentControl{Content=fields,HorizontalContentAlignment=HorizontalAlignment.Stretch};var error=Sans("",14,Red).Wrap();var content=VStack(20,V3DialogHead.Make(title,subtitle),form,error);
            var cancel=new V3Button("取消",()=>{if(!busy)close();},height:36,width:80);
            V3Button? button=null;button=new V3Button(submit,()=>_=Submit(),V3Button.Kind.Dark,height:36);
            async Task Submit(){if(busy||stamp!=Stamp||allowed?.Invoke()==false)return;busy=true;form.IsEnabled=false;cancel.Enabled=button!.Enabled=false;button.Title="保存中…";error.Text="";try{await save();if(stamp==Stamp){close();Render();}}catch(OperationCanceledException){}catch(Exception ex){if(stamp==Stamp){error.Text=ex is InvalidOperationException?ex.Message:Explain(ex);_error=error.Text;}}finally{if(stamp==Stamp){busy=false;form.IsEnabled=true;cancel.Enabled=button.Enabled=true;button.Title=submit;}}}
            return V3Dialog.Make(content,[cancel,button],()=>{if(!busy)close();},width,closable:true);
        },dismissible:false);
    }
    void EditProfile()
    {
        var stamp=Stamp;var picking=false;var nickname=Input(User.Text("nickname"),"昵称",40);nickname.MaxLength=50;
        AvatarCrop.Draft? draft=null;byte[]? bytes=null;ImageSource? picked=null;var remove=false;
        var crop=new Canvas {Width=232,Height=232,Background=Brush(Field),IsTabStop=true}.Tip("头像裁剪区域，可使用方向键移动");var previews=new StackPanel {Orientation=Orientation.Horizontal,Spacing=16};
        var zoom=new Slider {Minimum=1,Maximum=3,Value=1,Width=180,IsEnabled=false};
        void Paint(){crop.Children.Clear();previews.Children.Clear();var source=remove?null:picked??_avatar;
            if(draft is {} d && source is not null){var layout=AvatarCrop.Measure(d);var scale=232/AvatarCrop.Viewport;var image=new Image {Source=source,Width=layout.RenderedWidth*scale,Height=layout.RenderedHeight*scale,Stretch=Stretch.Fill};Canvas.SetLeft(image,(232-image.Width)/2+d.OffsetX*scale);Canvas.SetTop(image,(232-image.Height)/2+d.OffsetY*scale);crop.Children.Add(image);}
            else{var avatar=Avatar(source,Initial,AvatarCrop.Window*232/AvatarCrop.Viewport);Canvas.SetLeft(avatar,(232-avatar.Width)/2);Canvas.SetTop(avatar,(232-avatar.Height)/2);crop.Children.Add(avatar);}
            crop.Clip=new RectangleGeometry {Rect=new Windows.Foundation.Rect(0,0,232,232)};
            var mask=new Microsoft.UI.Xaml.Shapes.Path {Fill=Brush(Alpha(Txt,.45)),Data=new GeometryGroup {FillRule=FillRule.EvenOdd,Children={new RectangleGeometry {Rect=new Windows.Foundation.Rect(0,0,232,232)},new EllipseGeometry {Center=new Windows.Foundation.Point(116,116),RadiusX=AvatarCrop.Window*232/640,RadiusY=AvatarCrop.Window*232/640}}}};mask.IsHitTestVisible=false;crop.Children.Add(mask);
            var hint=Fill(Alpha(Txt,.8),11,child:Sans(draft is null?"点击选择图片":"拖动调整位置",10.5,White).Align(HorizontalAlignment.Center,VerticalAlignment.Center)).Frame(width:120,height:22);Canvas.SetLeft(hint,56);Canvas.SetTop(hint,198);hint.IsHitTestVisible=false;crop.Children.Add(hint);
            foreach(var size in new[]{56d,36,24}){if(draft is {} p && source is not null){var transform=new TransformGroup();transform.Children.Add(new ScaleTransform {ScaleX=p.Zoom,ScaleY=p.Zoom,CenterX=.5,CenterY=.5});transform.Children.Add(new TranslateTransform {X=p.OffsetX/AvatarCrop.Window,Y=p.OffsetY/AvatarCrop.Window});previews.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse {Width=size,Height=size,Fill=new ImageBrush {ImageSource=source,Stretch=Stretch.UniformToFill,RelativeTransform=transform}});}else previews.Children.Add(Avatar(source,Initial,size));}}
        async Task Pick(){if(picking||App.NativeWindow is not {} window)return;picking=true;try{var picker=new Windows.Storage.Pickers.FileOpenPicker();foreach(var extension in new[]{".png",".jpg",".jpeg",".webp"})picker.FileTypeFilter.Add(extension);WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(window));var file=await picker.PickSingleFileAsync();if(file is null||stamp!=Stamp||_disposed)return;try{using var stream=await file.OpenReadAsync();if(stream.Size>10*1024*1024)throw new InvalidOperationException("头像图片不能超过 10MB。");var decoder=await BitmapDecoder.CreateAsync(stream);if(decoder.PixelWidth==0||decoder.PixelHeight==0||(ulong)decoder.PixelWidth*decoder.PixelHeight>40_000_000)throw new InvalidOperationException("头像图片无法读取，请选择其他图片。");stream.Seek(0);var buffer=new byte[(int)stream.Size];using(var reader=new DataReader(stream)){await reader.LoadAsync((uint)buffer.Length);reader.ReadBytes(buffer);}using var memory=new InMemoryRandomAccessStream();using(var writer=new DataWriter(memory.GetOutputStreamAt(0))){writer.WriteBytes(buffer);await writer.StoreAsync();}memory.Seek(0);var image=new BitmapImage();await image.SetSourceAsync(memory);if(stamp!=Stamp||_disposed)return;bytes=await NormalizePng(buffer);using var normalized=new MemoryStream(bytes).AsRandomAccessStream();var normalizedDecoder=await BitmapDecoder.CreateAsync(normalized);normalized.Seek(0);await image.SetSourceAsync(normalized);if(stamp!=Stamp||_disposed)return;picked=image;draft=new(normalizedDecoder.PixelWidth,normalizedDecoder.PixelHeight);remove=false;zoom.Value=1;zoom.IsEnabled=true;Paint();}catch(Exception ex){if(stamp==Stamp)Toast(ex is InvalidOperationException?ex.Message:"头像图片无法读取，请选择其他图片。",true);}}finally{picking=false;}}
        crop.KeyDown+=(_,e)=>{if(draft is not {} d)return;var dx=e.Key==Windows.System.VirtualKey.Left?-4:e.Key==Windows.System.VirtualKey.Right?4:0;var dy=e.Key==Windows.System.VirtualKey.Up?-4:e.Key==Windows.System.VirtualKey.Down?4:0;if(dx==0&&dy==0)return;e.Handled=true;draft=AvatarCrop.Clamp(d with{OffsetX=d.OffsetX+dx,OffsetY=d.OffsetY+dy});Paint();};
        crop.PointerReleased+=(_,_)=>{if(draft is null)_=Pick();};crop.ManipulationMode=ManipulationModes.TranslateX|ManipulationModes.TranslateY;
        crop.ManipulationDelta+=(_,e)=>{if(draft is {} d){draft=AvatarCrop.Clamp(d with {OffsetX=d.OffsetX+e.Delta.Translation.X*320/232,OffsetY=d.OffsetY+e.Delta.Translation.Y*320/232});Paint();}};
        zoom.ValueChanged+=(_,_)=>{if(draft is {} d){draft=AvatarCrop.Clamp(d with {Zoom=zoom.Value});Paint();}};
        var count=Sans(nickname.Text.Length+" / 50",12,Fnt);nickname.TextChanged+=(_,_)=>count.Text=nickname.Text.Length+" / 50";
        var right=VStack(0,Spread(Sans("昵称*",14,Sub,Medium),count),nickname.Top(5),Sans("头像",14,Sub,Medium).Top(22),HStack(16,new V3Button("重新选择",()=>_=Pick(),height:34,width:112),LinkButton("移除头像",()=>{draft=null;bytes=null;picked=null;remove=true;zoom.IsEnabled=false;Paint();})).Top(5),Sans("支持 JPG、PNG、WebP，最大 10 MB。",14,Fnt).Wrap().Top(10),Sans("预览",14,Sub,Medium).Top(22),previews.Top(9));
        Paint();ShowForm("编辑资料","头像和昵称会显示在侧栏、分享页和 AI 对话里。",Columns(32,(Px(232),VStack(22,crop,HStack(17, Sans("缩放",12,Sub),zoom))),(Px(292),right)),620,async()=>{
            if(picking)throw new InvalidOperationException("请先完成图片选择。");var name=nickname.Text.Trim();if(name.Length==0||new System.Globalization.StringInfo(name).LengthInTextElements>50)throw new InvalidOperationException("昵称不能为空，且不能超过 50 个字符。");
            if(name!=User.Text("nickname"))ApplyUser(await Request("/api/account/profile","PATCH",new JsonObject {["nickname"]=name}));
            if(draft is {} d&&bytes is not null){var png=await CropPng(bytes,d);if(stamp!=Stamp||_disposed)throw new OperationCanceledException();var result=await Request("/api/account/avatar","PUT",new JsonObject {["fileName"]="avatar.png",["dataUrl"]="data:image/png;base64,"+Convert.ToBase64String(png)});var user=User!.DeepClone();user["avatar_url"]=result["url"]?.DeepClone();ApplyUser(user);Toast("头像已更新。");}
            else if(remove&&User.Text("avatar_url").Length>0){await Request("/api/account/avatar","DELETE");var user=User!.DeepClone();user["avatar_url"]=null;ApplyUser(user);Toast("头像已删除。");}else Toast("资料已保存。");
            await LoadAvatar();
        });
    }
    static async Task<byte[]> NormalizePng(byte[] bytes)
    {
        using var input=new MemoryStream(bytes).AsRandomAccessStream();var decoder=await BitmapDecoder.CreateAsync(input);
        var pixels=await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,new BitmapTransform(),ExifOrientationMode.RespectExifOrientation,ColorManagementMode.ColorManageToSRgb);
        using var output=new InMemoryRandomAccessStream();var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,output);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,decoder.OrientedPixelWidth,decoder.OrientedPixelHeight,96,96,pixels.DetachPixelData());await encoder.FlushAsync();output.Seek(0);
        using var reader=new DataReader(output);await reader.LoadAsync((uint)output.Size);var result=new byte[(int)output.Size];reader.ReadBytes(result);return result;
    }
    static async Task<byte[]> CropPng(byte[] bytes,AvatarCrop.Draft draft)
    {
        using var input=new InMemoryRandomAccessStream();using(var writer=new DataWriter(input.GetOutputStreamAt(0))){writer.WriteBytes(bytes);await writer.StoreAsync();}input.Seek(0);var decoder=await BitmapDecoder.CreateAsync(input);var source=AvatarCrop.Source(draft);
        var transform=new BitmapTransform {Bounds=new BitmapBounds {X=(uint)Math.Floor(source.X),Y=(uint)Math.Floor(source.Y),Width=(uint)Math.Min(Math.Ceiling(source.Size),decoder.PixelWidth-Math.Floor(source.X)),Height=(uint)Math.Min(Math.Ceiling(source.Size),decoder.PixelHeight-Math.Floor(source.Y))}};
        var pixels=await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,transform,ExifOrientationMode.IgnoreExifOrientation,ColorManagementMode.ColorManageToSRgb);
        using var output=new InMemoryRandomAccessStream();var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,output);encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,transform.Bounds.Width,transform.Bounds.Height,96,96,pixels.DetachPixelData());encoder.BitmapTransform.ScaledWidth=encoder.BitmapTransform.ScaledHeight=512;await encoder.FlushAsync();output.Seek(0);var result=new byte[(int)output.Size];using var reader=new DataReader(output);await reader.LoadAsync((uint)result.Length);reader.ReadBytes(result);return result;
    }
    static T Place<T>(Canvas canvas,T element,double x,double y) where T:FrameworkElement {Canvas.SetLeft(element,x);Canvas.SetTop(element,y);canvas.Children.Add(element);return element;}
    static void Bar(Canvas canvas,double x,double y,double w,double h,double r=2)=>Place(canvas,Fill(Sk2,r,w,h),x,y);
    static Canvas ArtPaper(Canvas stage,double x,double y,double w,double h,double radius=8){var canvas=new Canvas{Width=w,Height=h};Place(stage,Card(canvas,radius),x,y).Frame(width:w,height:h);return canvas;}
    static void Badge(Canvas stage,double x,double y,string icon,bool success=false)=>Place(stage,Fill(success?Green:Orange,12,24,24,Icon(icon,10,White).Align(HorizontalAlignment.Center,VerticalAlignment.Center)),x,y);
    static FrameworkElement EmailArt(string email)
    {
        var stage=new Canvas{Width=456,Height=120};var current=ArtPaper(stage,45,50,150,44,10);
        Place(current,Fill(Field,12,24,24,Icon("envelope",10,Sub).Align(HorizontalAlignment.Center,VerticalAlignment.Center)),10,10);
        Place(current,Sans("当前邮箱",9,Fnt),42,8);Place(current,Sans(email.Length>0?email:"未设置",10.5,Sub).Frame(width:100),42,21);
        var arrow=new Microsoft.UI.Xaml.Shapes.Path{Data=(Geometry)Microsoft.UI.Xaml.Markup.XamlReader.Load("<PathGeometry xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Figures='M2,7 L50,7 M48,3 L53,7 L48,11'/>"),Stroke=Brush(Hex(0xB9B9B3)),StrokeThickness=1.4,StrokeDashArray=new DoubleCollection{3,3}};Place(stage,arrow,211,65);
        Place(stage,Card(new Grid(),7,background:Hex(0xF1F1EE)).Frame(width:120,height:64),291,40);
        var digits=ArtPaper(stage,303,16,96,52,6);for(var i=0;i<6;i++)Place(digits,Fill(Field,3,12,16,Label("482913"[i].ToString(),10,Txt,Semibold).Align(HorizontalAlignment.Center,VerticalAlignment.Center)),5+i*15,10);Bar(digits,18,34,60,3,1.5);
        var pocket=new Microsoft.UI.Xaml.Shapes.Path{Data=(Geometry)Microsoft.UI.Xaml.Markup.XamlReader.Load("<PathGeometry xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Figures='M0.5,0.5 L60,26 L119.5,0.5 L119.5,31 Q119.5,37.5 113,37.5 L7,37.5 Q0.5,37.5 0.5,31 Z'/>"),Fill=Brush(White),Stroke=Brush(Cl)};Place(stage,pocket,291,66);Badge(stage,395,30,"checkmark",true);return stage;
    }
    FrameworkElement LogoutArt()
    {
        var stage=new Canvas{Width=372,Height=128};var computer=ArtPaper(stage,112,22,136,86);
        Place(computer,Fill(Field,0,136,16),0,0);foreach(var x in new[]{8,17,26})Bar(computer,x,5,6,6,3);
        Place(computer,Avatar(null,Initial,20),14,30);Place(computer,Fill(Txt,2,52,5),42,33);Bar(computer,42,43,34,4);Bar(computer,14,62,108,4);Bar(computer,14,72,80,4);Badge(stage,236,90,"rectangle.portrait.and.arrow.right");
        var phone=ArtPaper(stage,272,34,40,70,6);((FrameworkElement)stage.Children[^1]).Opacity=.45;Bar(phone,14,6,12,3);Place(phone,Avatar(null,Initial,16),12,20);Bar(phone,8,44,24,3);Bar(phone,8,52,18,3);return stage;
    }
}
