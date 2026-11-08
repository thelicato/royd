package org.royd.policyusage;

import android.net.INetworkPolicyManager;
import android.net.INetworkStatsService;
import android.net.INetworkStatsSession;
import android.net.NetworkPolicy;
import android.net.NetworkStats;
import android.net.NetworkTemplate;
import android.os.Process;
import android.os.ServiceManager;
import android.os.SystemClock;
import android.util.Range;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import org.json.JSONArray;
import org.json.JSONObject;

/** Owned-instance policy validation using stock privileged Binder operations. */
public final class PolicyUsageProbe {
    private static void need(boolean v, String message) {
        if (!v) throw new IllegalStateException(message);
    }
    private static JSONObject describe(NetworkPolicy p) throws Exception {
        return new JSONObject().put("match_rule", p.template.getMatchRule())
            .put("meteredness", p.template.getMeteredness()).put("limit", p.limitBytes)
            .put("warning", p.warningBytes).put("last_limit_snooze", p.lastLimitSnooze)
            .put("last_warning_snooze", p.lastWarningSnooze).put("last_rapid_snooze", p.lastRapidSnooze)
            .put("metered", p.metered)
            .put("inferred", p.inferred).put("cycle", p.cycleRule.toString());
    }
    public static void main(String[] args) throws Exception {
        need(args.length >= 2 && args[0].matches("[0-9a-f]{32}") && Process.myUid() == 0, "arguments/root UID");
        String nonce=args[0], op=args[1];
        INetworkPolicyManager npm=INetworkPolicyManager.Stub.asInterface(ServiceManager.checkService("netpolicy"));
        INetworkStatsService nss=INetworkStatsService.Stub.asInterface(ServiceManager.checkService("netstats"));
        need(npm != null && nss != null, "policy/stats service missing");
        NetworkPolicy[] before=npm.getNetworkPolicies("android");
        NetworkTemplate template=new NetworkTemplate.Builder(NetworkTemplate.MATCH_ETHERNET).build();
        NetworkPolicy policy=new NetworkPolicy(template, NetworkPolicy.buildRule(1, ZoneOffset.UTC),
            NetworkPolicy.WARNING_DISABLED, NetworkPolicy.LIMIT_DISABLED,
            NetworkPolicy.SNOOZE_NEVER, NetworkPolicy.SNOOZE_NEVER, true, false);
        if (op.equals("set")) {
            need(args.length==3 && before.length==0, "set requires initially empty policy set");
            policy.limitBytes=Long.parseLong(args[2]);need(policy.limitBytes > 0, "positive limit");
            npm.setNetworkPolicies(new NetworkPolicy[]{policy});
        } else if (op.equals("remove")) {
            need(args.length==3 && before.length==1 && before[0].template.equals(template)
                && before[0].limitBytes==Long.parseLong(args[2])
                && before[0].warningBytes==NetworkPolicy.WARNING_DISABLED
                && before[0].lastLimitSnooze==NetworkPolicy.SNOOZE_NEVER
                && before[0].lastWarningSnooze==NetworkPolicy.SNOOZE_NEVER
                && before[0].lastRapidSnooze==NetworkPolicy.SNOOZE_NEVER
                && before[0].metered && !before[0].inferred
                && before[0].cycleRule.equals(policy.cycleRule), "changed policy ownership");
            npm.setNetworkPolicies(new NetworkPolicy[0]);
        } else {
            need(args.length==2 && (op.equals("inspect") || op.equals("poll")), "operation");
            if(op.equals("poll")) nss.forceUpdate();
        }
        Range<ZonedDateTime> cycle=policy.cycleIterator().next();
        long start=cycle.getLower().toInstant().toEpochMilli(), end=cycle.getUpper().toInstant().toEpochMilli();
        // Legacy privileged openSession avoids claiming an ordinary package UID.
        // Its subscription-plan flag has no POLL_ON_OPEN bit; root retains stock permission checks.
        INetworkStatsSession session=nss.openSession();
        NetworkStats total;
        try { total=session.getSummaryForNetwork(template,start,end); }
        finally { session.close(); }
        NetworkPolicy[] after=npm.getNetworkPolicies("android");JSONArray policies=new JSONArray();
        for(NetworkPolicy p:after)policies.put(describe(p));
        System.out.println(new JSONObject().put("nonce",nonce).put("operation",op)
            .put("uid",Process.myUid()).put("pid",Process.myPid()).put("sampled_ns",SystemClock.elapsedRealtimeNanos())
            .put("policies",policies).put("cycle_start_ms",start).put("cycle_end_ms",end)
            .put("recorded_bytes",total.getTotalBytes()).put("stats",total.toString()));
        System.exit(0);
    }
}
