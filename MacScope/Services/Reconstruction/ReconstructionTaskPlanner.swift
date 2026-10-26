import Foundation

enum ReconstructionTaskPlanningError: Error, Equatable, Sendable {
    case crossJobTask
    case taskBudgetExceeded
}

struct ReconstructionTaskPlanner: Sendable {
    func readyTasks(
        from tasks: [ReconstructionTaskRecord],
        jobID: UUID,
        maximumTasks: Int
    ) throws -> [ReconstructionTaskRecord] {
        guard maximumTasks > 0, tasks.count <= maximumTasks else {
            throw ReconstructionTaskPlanningError.taskBudgetExceeded
        }
        guard tasks.allSatisfy({ $0.identity.jobID == jobID }) else {
            throw ReconstructionTaskPlanningError.crossJobTask
        }
        let completed = Set(tasks.compactMap {
            $0.state == .completed ? $0.identity.taskID : nil
        })
        return tasks.filter { task in
            task.state == .pending
                && task.identity.dependencyTaskIDs.allSatisfy(completed.contains)
        }.sorted { lhs, rhs in
            if lhs.identity.kind.rawValue != rhs.identity.kind.rawValue {
                return lhs.identity.kind.rawValue < rhs.identity.kind.rawValue
            }
            if lhs.identity.canonicalSHA256 != rhs.identity.canonicalSHA256 {
                return lhs.identity.canonicalSHA256 < rhs.identity.canonicalSHA256
            }
            return lhs.identity.taskID.uuidString.lowercased()
                < rhs.identity.taskID.uuidString.lowercased()
        }
    }
}
