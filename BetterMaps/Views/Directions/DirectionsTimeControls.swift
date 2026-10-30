import SwiftUI

/// "Leave now" or a chosen time, with an arrive-by switch once a time is
/// set. Pure value view; the sheet owns the state.
struct DirectionsTimeControls: View {
    let departNow: Bool
    let time: Date
    let arriveBy: Bool
    let onSetDepartNow: (Bool) -> Void
    let onSetTime: (Date) -> Void
    let onSetArriveBy: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("When", selection: Binding(get: { departNow }, set: { onSetDepartNow($0) })) {
                Text("Leave now").tag(true)
                Text("At a time").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !departNow {
                HStack(spacing: 12) {
                    DatePicker("Time", selection: Binding(get: { time }, set: { onSetTime($0) }),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    Spacer(minLength: 0)
                    Toggle("Arrive by", isOn: Binding(get: { arriveBy }, set: { onSetArriveBy($0) }))
                        .font(.subheadline)
                        .fixedSize()
                }
                .frame(minHeight: 44)
            }
        }
    }
}
