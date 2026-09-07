import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/printing/print_service.dart';
import '../state/app_state.dart';

/// 打印任务监控窗：队列/历史、取消、暂停/恢复、配额进度。
class PrintJobsPage extends StatelessWidget {
  const PrintJobsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = PrintService.instance;
    final quota = context.watch<AppState>().settings.printDailyPages;
    return Scaffold(
      appBar: AppBar(
        title: const Text('打印任务'),
        actions: [
          IconButton(
            tooltip: svc.paused ? '恢复打印' : '暂停打印',
            icon: Icon(svc.paused ? Icons.play_circle_outline : Icons.pause_circle_outline),
            onPressed: () => svc.setPaused(!svc.paused),
          ),
          IconButton(
            tooltip: '全部取消',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: () {
              svc.cancelAll();
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未开始的任务已全部取消')));
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          final jobs = svc.jobs;
          final used = svc.todayPagesUsed;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Text('今日配额  $used / $quota 页',
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: quota <= 0 ? 0 : (used / quota).clamp(0.0, 1.0),
                      ),
                    ),
                  ],
                ),
              ),
              if (svc.paused)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Chip(
                      avatar: Icon(Icons.pause, size: 16),
                      label: Text('打印已暂停'),
                    ),
                  ),
                ),
              Expanded(
                child: jobs.isEmpty
                    ? const Center(child: Text('暂无打印任务'))
                    : ListView.builder(
                        itemCount: jobs.length,
                        itemBuilder: (context, i) =>
                            _JobTile(job: jobs[i], svc: svc),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final PrintJob job;
  final PrintService svc;
  const _JobTile({required this.job, required this.svc});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (job.state) {
      JobState.queued => ('排队中', Colors.blueGrey),
      JobState.held => ('等待文档', Colors.blueGrey),
      JobState.printing => ('打印中', Colors.blue),
      JobState.done => ('已完成', Colors.green),
      JobState.failed => ('失败', Colors.red),
      JobState.canceled => ('已取消', Colors.grey),
    };
    final opts = <String>[
      if (job.copies > 1) '${job.copies} 份',
      if (job.pages.isNotEmpty) '页码 ${job.pages}',
      if (job.duplex.isNotEmpty) job.duplex == 'long' ? '双面(长边)' : '双面(短边)',
      if (job.color) '彩色',
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Chip(
          label: Text(label,
              style: TextStyle(fontSize: 11, color: Colors.white)),
          backgroundColor: color,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact),
      title: Text(job.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          job.clientName,
          if (opts.isNotEmpty) opts,
          if (job.error != null) '错误: ${job.error}',
          _fmtTime(job.submittedAt),
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: (job.state == JobState.queued || job.state == JobState.held)
          ? IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: '取消此任务',
              onPressed: () => svc.cancelJob(job.id),
            )
          : null,
    );
  }

  static String _fmtTime(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
