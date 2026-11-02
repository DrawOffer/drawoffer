using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 完整岗位字段编辑，对应 Mac `JobFieldsSheet`（Web 详情页的逐项编辑合并为一张表单）：640×720，
/// 分「岗位 / 薪资 / 岗位描述 / 公司」四组，PUT 提交完整字段与 base_lock_version。
/// </summary>
static class JobFieldsSheet
{
    public static void Show(XamlRoot root, JsonNode job, Action<JsonNode> saved)
    {
        var values = new Dictionary<string, string>();
        foreach (var key in new[] { "job_title", "company_name", "description" }.Concat(JobDescriptionFields.OptionalText)) values[key] = job.Text(key);
        values["skills"] = string.Join(", ", job.Items("skills").Select(x => x.String()).OfType<string>());
        values["salary_months_per_year"] = job.Number("salary_months_per_year") is { } months ? ((int)months).ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
        var busy = false;
        var error = Sans("", 12.5, CareerPalette.Red).Wrap();
        error.Visibility = Visibility.Collapsed;
        V3Overlay.Show(root, close =>
        {
            TextBox Field(string key, string placeholder, bool multiline = false, double minHeight = 0)
            {
                var box = new TextBox
                {
                    Text = values[key], PlaceholderText = multiline ? "" : placeholder, FontSize = 13, FontFamily = SansFamily, AcceptsReturn = multiline,
                    TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multiline ? minHeight : 0,
                    CornerRadius = new CornerRadius(6), BorderBrush = Brush(CareerPalette.Control), BorderThickness = new Thickness(1), Background = Brush(V3.White),
                };
                // Mac 的多行 `TextEditor` 没有占位文字；这里只作读屏名称
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, placeholder);
                box.TextChanged += (_, _) => values[key] = box.Text;
                return box;
            }
            FrameworkElement Picker(string title, string key, (string Value, string Label)[] options)
            {
                var box = new ComboBox { FontSize = 13, MinWidth = 160, HorizontalAlignment = HorizontalAlignment.Right };
                box.Items.Add("未填写");
                foreach (var option in options) box.Items.Add(option.Label);
                var index = Array.FindIndex(options, o => o.Value == values[key]);
                box.SelectedIndex = index + 1;
                box.SelectionChanged += (_, _) => values[key] = box.SelectedIndex <= 0 ? "" : options[box.SelectedIndex - 1].Value;
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
                return Columns(12, (Star(), Sans(title, 13, CareerPalette.Text).Align(v: VerticalAlignment.Center)), (Auto, box));
            }
            // `.formStyle(.grouped)`：组标题 + 浅灰底圆角分组
            FrameworkElement Group(string title, params UIElement[] rows) => VStack(6,
                Sans(title, 11.5, CareerPalette.Faint, Medium).Pad(4, 0, 0, 0),
                new Border { Child = VStack(10, rows), Padding = new Thickness(14), CornerRadius = new CornerRadius(10), Background = Brush(CareerPalette.Soft), BorderBrush = Brush(CareerPalette.Line), BorderThickness = new Thickness(1) });

            var currency = Field("salary_currency", "币种");
            currency.Width = 90;
            var form = VStack(18,
                Group("岗位",
                    Field("job_title", "职位名称（必填）"), Field("company_name", "公司名称（必填）"),
                    Picker("求职分类", "employment_type", JobDescriptionFields.Employment),
                    Field("work_city", "工作地点"), Picker("工作方式", "work_mode", JobDescriptionFields.WorkMode),
                    Field("education_requirement", "学历要求"), Field("experience_requirement", "经验要求"),
                    Field("work_schedule", "工作安排"), Field("work_address", "详细地址")),
                Group("薪资",
                    Field("salary_text", "薪资原文（页头显示）"),
                    Columns(8, (Star(), Field("salary_min", "最低")), (Star(), Field("salary_max", "最高")), (Px(90), currency)),
                    Picker("计薪周期", "salary_period", JobDescriptionFields.SalaryPeriod),
                    Field("salary_months_per_year", "年薪月数")),
                Group("岗位描述（支持 Markdown，## 开头是小标题）",
                    Field("description", "岗位描述", multiline: true, minHeight: 180), Field("skills", "核心技能（用逗号分隔）")),
                Group("公司",
                    Field("company_legal_name", "公司全称"), Field("logo_url", "公司 Logo URL"), Field("company_industry", "行业"),
                    Field("company_size", "公司规模"), Field("company_financing_stage", "融资阶段"), Field("recruiter_name", "招聘者姓名"),
                    Field("recruiter_title", "招聘者职位"), Field("company_description", "公司介绍", multiline: true, minHeight: 80)));
            form.Padding = new Thickness(24, 0, 24, 12);

            var cancel = new CareerAction("取消", close) { Enabled = true };
            CareerAction? save = null;
            void Busy(bool value) { busy = value; cancel.Enabled = !value; save!.Enabled = !value; save.Title = value ? "保存中…" : "保存"; }
            void Fail(string message) { error.Text = message; error.Visibility = Visibility.Visible; }
            save = new CareerAction("保存", async () =>
            {
                if (busy) return;
                if (values["job_title"].Trim(' ', '\t').Length == 0 || values["company_name"].Trim(' ', '\t').Length == 0) { Fail("职位名称和公司名称为必填项。"); return; }
                var monthsText = values["salary_months_per_year"].Trim(' ', '\t');
                if (monthsText.Length > 0 && !int.TryParse(monthsText, System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out _))
                { Fail("年薪月数需要填写整数。"); return; }
                Busy(true);
                error.Visibility = Visibility.Collapsed;
                try
                {
                    var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{job.Text("id")}", "PUT", [], JobDescriptionFields.Payload(job, values));
                    close();
                    saved(result.Get("job_description") ?? job);
                }
                catch (Exception failure) { Fail(JobDescriptionFields.ErrorMessage(failure, "保存岗位失败，请稍后重试。")); }
                finally { Busy(false); }
            }, CareerAction.Kind.Primary);
            var foot = HStack(10, cancel, save);
            foot.HorizontalAlignment = HorizontalAlignment.Right;
            foot.Margin = new Thickness(24);

            var grid = new Grid { Height = 720 };
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.Children.Add(Serif("编辑岗位", 20).Pad(24, 24, 24, 24));
            var scroll = new ScrollViewer { Content = form, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
            var errorRow = error.Pad(24, 0, 24, 0);
            Grid.SetRow(errorRow, 2); grid.Children.Add(errorRow);
            Grid.SetRow(foot, 3); grid.Children.Add(foot);
            return V3Dialog.Frame(grid, 640);
        }, dismissible: false);
    }
}
