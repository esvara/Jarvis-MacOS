import { nanoid } from "nanoid";
import type {
  ApprovalKind,
  ApprovalRequest,
  BackendApprovalDecision
} from "../../shared/types";

type PendingApproval = {
  request: ApprovalRequest;
  resolve: (decision: BackendApprovalDecision) => void;
  reject: (error: Error) => void;
};

export class ApprovalHub {
  private readonly pending = new Map<string, PendingApproval>();

  createRequest(args: {
    taskId: string;
    kind: ApprovalKind;
    toolName: string;
    summary: string;
    detail?: string;
    rawItem: unknown;
  }): {
    request: ApprovalRequest;
    waitForDecision: Promise<BackendApprovalDecision>;
  } {
    const id = nanoid();
    const request: ApprovalRequest = {
      id,
      taskId: args.taskId,
      kind: args.kind,
      toolName: args.toolName,
      summary: args.summary,
      detail: args.detail,
      rawItem: args.rawItem,
      createdAt: new Date().toISOString()
    };

    const waitForDecision = new Promise<BackendApprovalDecision>((resolve, reject) => {
      this.pending.set(id, { request, resolve, reject });
    });

    return { request, waitForDecision };
  }

  resolve(decision: BackendApprovalDecision): void {
    const pending = this.pending.get(decision.approvalId);
    if (!pending) {
      return;
    }
    this.pending.delete(decision.approvalId);
    pending.resolve(decision);
  }

  rejectTask(taskId: string, reason = "Task cancelled"): void {
    for (const [approvalId, pending] of this.pending.entries()) {
      if (pending.request.taskId !== taskId) {
        continue;
      }
      this.pending.delete(approvalId);
      pending.reject(new Error(reason));
    }
  }
}
