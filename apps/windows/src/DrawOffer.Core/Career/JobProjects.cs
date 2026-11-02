using System.Globalization;
using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>
/// 资料库「求职进程」项目（Web `datasets/jobProjects.ts`，Mac `JobProjects.swift`）：
/// 不单独存储，由投递 + 面试场次 + 关联到场次的资料 + Offer 材料聚合。
/// </summary>
public static class JobProjects
{
    public enum State { Done, Current, Upcoming, Offer }

    public sealed record Node(string Key, string Label, State State, string? Date, string? SessionId, IReadOnlyList<DatasetRecord> Datasets);

    public sealed record Project(string Id, JsonNode Application, string Name, string Monogram, string StatusLabel, bool Archived,
        IReadOnlyList<Node> Nodes, int DatasetCount, int RecordCount, double LastActivity)
    {
        public bool Offer => Application.Text("offer_status") is "received" or "accepted";

        /// <summary>下一场：没归档时第一个 current 节点。</summary>
        public Node? Next => Archived ? null : Nodes.FirstOrDefault(x => x.State == State.Current);

        /// <summary>强调「下一场」，没有下一场时强调最后走到的阶段。</summary>
        public string? FocusKey => (Next ?? Nodes.LastOrDefault(x => x.State != State.Upcoming))?.Key;

        /// <summary>阶段链最多 5 个阶段：保留投递和最近 3 个，中间用省略号（null）。</summary>
        public IReadOnlyList<Node?> Chain => Nodes.Count <= 5 ? Nodes.Cast<Node?>().ToList() : [Nodes[0], null, .. Nodes.Skip(Nodes.Count - 3)];

        public string MaterialSummary
        {
            get
            {
                var parts = new[] { DatasetCount > 0 ? $"{DatasetCount} 份资料" : "", RecordCount > 0 ? $"{RecordCount} 份记录" : "" }.Where(x => x.Length > 0).ToList();
                return parts.Count == 0 ? "还没有资料" : string.Join(" · ", parts);
            }
        }
    }

    /// <summary>`State.rawValue`。</summary>
    public static string RawValue(this State state) => state switch
    {
        State.Done => "done", State.Current => "current", State.Upcoming => "upcoming", _ => "offer",
    };

    /// <summary>秒级 Unix 时间；解析失败为 0。</summary>
    public static double Time(string? value) =>
        value is not null && CareerApplication.Date(value) is { } date ? (date - DateTimeOffset.UnixEpoch).TotalSeconds : 0;

    public static string Name(JsonNode application)
    {
        var company = SwiftText.TrimAll(application.Text("company_name_snapshot"));
        var title = SwiftText.TrimAll(application.Text("job_title_snapshot"));
        return company.Length > 0 && title.Length > 0 ? $"{company} · {title}" : company.Length == 0 ? (title.Length == 0 ? "未命名岗位" : title) : company;
    }

    public static string StatusLabel(JsonNode application, DateTimeOffset? now = null)
    {
        if (application.Text("archived_at").Length > 0) return "已归档";
        if (application.Text("offer_status") is "received" or "accepted") return "已获 Offer";
        return CareerBoard.ProgressLabel(application, false, now);
    }

    public static List<Project> Build(IEnumerable<JsonNode> applications, IEnumerable<JsonNode> sessions, IEnumerable<DatasetRecord> datasets, DateTimeOffset? now = null)
    {
        var byApplication = new Dictionary<string, List<JsonNode>>();
        foreach (var session in sessions.Where(x => x.Text("status") != "cancelled"))
        {
            var key = session.Display("application_id");
            if (!byApplication.TryGetValue(key, out var list)) byApplication[key] = list = [];
            list.Add(session);
        }
        var bySession = new Dictionary<string, List<DatasetRecord>>();
        var byId = new Dictionary<string, DatasetRecord>();
        foreach (var dataset in datasets)
        {
            byId[dataset.Id] = dataset;
            var session = dataset.Raw.Display("interview_session_id");
            if (session.Length == 0) continue;
            if (!bySession.TryGetValue(session, out var list)) bySession[session] = list = [];
            list.Add(dataset);
        }

        var projects = applications.Where(x => x.Text("phase") != "pending").Select(application =>
        {
            var id = application.Display("id");
            var ordered = CareerJson.StableSort(byApplication.GetValueOrDefault(id) ?? [], (a, b) => Time(a.Text("start_at")).CompareTo(Time(b.Text("start_at"))));
            var firstUpcoming = ordered.FindIndex(x => x.Text("status") == "scheduled");
            var nodes = new List<Node> { new("applied", "投递", State.Done, application.Text("applied_at").NonEmpty() ?? application.Text("created_at"), null, []) };
            for (var index = 0; index < ordered.Count; index++)
            {
                var session = ordered[index];
                var sid = session.Display("id");
                var label = SwiftText.TrimAll(session.Text("stage_label"));
                var state = session.Text("status") == "completed" ? State.Done : index == firstUpcoming ? State.Current : State.Upcoming;
                var attached = CareerJson.StableSort(bySession.GetValueOrDefault(sid) ?? [], (a, b) => Time(a.Raw.Text("created_at")).CompareTo(Time(b.Raw.Text("created_at"))));
                nodes.Add(new($"session-{sid}", label.Length == 0 ? "面试" : label, state, session.Text("start_at"), sid, attached));
            }
            var offerDatasets = application.Items("offer_materials").Select(x => byId.GetValueOrDefault(x.Display("dataset_id"))).OfType<DatasetRecord>().ToList();
            if (application.Text("offer_status") is "received" or "accepted" || offerDatasets.Count > 0)
                nodes.Add(new("offer", "Offer", State.Offer, application.Text("offer_received_on").NonEmpty(), null, offerDatasets));
            var all = nodes.SelectMany(x => x.Datasets).ToList();
            var records = ordered.Count(x => SwiftText.TrimAll(x.Text("questions_markdown")).Length > 0 || x.Items("written_questions").Count > 0);
            var last = new[] { Time(application.Text("updated_at")) }.Concat(all.Select(x => Time(x.Raw.Text("created_at")))).Max();
            var name = Name(application);
            var company = SwiftText.TrimAll(application.Text("company_name_snapshot"));
            var monogram = SwiftText.Prefix(company.Length == 0 ? name : company, 1).Or("·");
            return new Project(id, application, name, monogram, StatusLabel(application, now), application.Text("archived_at").Length > 0,
                nodes, all.Count, records, last);
        }).ToList();

        return CareerJson.StableSort(projects, (a, b) =>
        {
            if (a.Archived != b.Archived) return a.Archived ? 1 : -1;
            return b.LastActivity.CompareTo(a.LastActivity);
        });
    }

    /// <summary>每份资料所在项目的显示名：求职进程项目优先。</summary>
    public static Dictionary<string, string> Labels(IEnumerable<Project> projects)
    {
        var labels = new Dictionary<string, string>();
        foreach (var project in projects)
            foreach (var node in project.Nodes)
                foreach (var dataset in node.Datasets) labels[dataset.Id] = project.Name;
        return labels;
    }

    /// <summary>`formatDatasetFileSize`：B / KB / MB / GB，整数不带小数，否则保留一位。</summary>
    public static string Size(double bytes)
    {
        static string Unit(double value) => SwiftText.Rounded(value) == value ? ((long)value).ToString(CultureInfo.InvariantCulture) : SwiftText.Fixed1(value);
        if (bytes < 1024) return ((long)bytes).ToString(CultureInfo.InvariantCulture) + " B";
        if (bytes < 1024 * 1024) return Unit(bytes / 1024) + " KB";
        if (bytes < 1024 * 1024 * 1024) return Unit(bytes / 1024 / 1024) + " MB";
        return Unit(bytes / 1024 / 1024 / 1024) + " GB";
    }
}
