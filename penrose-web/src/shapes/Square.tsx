import * as React from "react";
import { toScreen, toHex } from "utils/Util";
import { IGPIProps } from "types";

class Square extends React.Component<IGPIProps> {
  public render() {
    const { shape } = this.props;
    const { canvasSize } = this.props;
    const [x, y] = toScreen([shape.center.contents[0], shape.center.contents[1]], canvasSize);
    const color = toHex(shape.color.contents);
    const alpha = shape.color.contents.contents[3];
    const strokeColor = toHex(shape.strokeColor.contents);
    const side = shape.side.contents;
    const strokeWidth = shape.strokeWidth.contents;

    return (
      <rect
        x={x - side / 2}
        y={y - side / 2}
        width={side}
        height={side}
        fill={color}
        fillOpacity={alpha}
        strokeWidth={strokeWidth}
        strokeDasharray={shape.strokeStyle.contents === "dashed" ? "7, 5" : ""}
        stroke={strokeColor}
      >
        <title>{shape.name.contents}</title>
      </rect>
    );
  }
}
export default Square;
