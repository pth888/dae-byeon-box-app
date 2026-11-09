import 'package:flutter/material.dart';

typedef RoadSelectionChanged = void Function(int place, String? otherAction);

const roadLabels = <String>[
  '직선',
  '신호교차로',
  '무신호교차로',
  'T자형',
  '고속도로',
  '주차장',
  '회전교차로',
  '차도·비차도',
];

const _signalActions = <String, String>{
  'left': '좌회전 중',
  'right': '우회전 중',
  'u_turn': '유턴 중',
  'straight_other': '직진·그 밖의 움직임',
  'unknown': '잘 모르겠음',
};

const _roundaboutActions = <String, String>{
  'entering': '회전교차로로 들어오는 중',
  'circulating': '회전교차로 안을 도는 중',
  'lane_change': '회전교차로 안에서 차로를 바꾸는 중',
  'unknown': '잘 모르겠음',
};

class RoadQuestionWidget extends StatelessWidget {
  const RoadQuestionWidget({
    super.key,
    required this.selectedPlace,
    required this.selectedAction,
    required this.onChanged,
    this.isBusy = false,
    this.roadLocked = false,
  });

  final int? selectedPlace;
  final String? selectedAction;
  final RoadSelectionChanged onChanged;
  final bool isBusy;
  final bool roadLocked;

  @override
  Widget build(BuildContext context) {
    final actions = selectedPlace == 1
        ? _signalActions
        : selectedPlace == 6
            ? _roundaboutActions
            : null;
    final question = selectedPlace == 1
        ? '사고 직전 상대 차는 어떻게 움직이고 있었나요?'
        : '사고 직전 상대 차는 회전교차로에서 어떤 상태였나요?';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(roadLabels.length, (place) {
            final selected = selectedPlace == place;
            return ChoiceChip(
              key: Key('road-option-$place'),
              avatar: selected ? const Icon(Icons.check, size: 16) : null,
              label: Text(roadLabels[place]),
              selected: selected,
              showCheckmark: false,
              onSelected: isBusy || roadLocked
                  ? null
                  : (_) => onChanged(
                        place,
                        place == selectedPlace ? selectedAction : null,
                      ),
            );
          }),
        ),
        if (actions != null) ...[
          const SizedBox(height: 20),
          Text('상대 차량 움직임 (선택)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Semantics(
            key: const Key('road-secondary-question'),
            header: true,
            child: Text(
              question,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: actions.entries.map((entry) {
              return ChoiceChip(
                key: Key('road-action-${entry.key}'),
                label: Text(entry.value),
                selected: selectedAction == entry.key,
                onSelected: isBusy
                    ? null
                    : (selected) =>
                        onChanged(selectedPlace!, selected ? entry.key : null),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}
