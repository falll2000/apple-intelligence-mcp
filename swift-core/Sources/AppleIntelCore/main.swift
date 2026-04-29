import Foundation

// main.swift 作為 top-level 入口點，不能用 @main
// 用 Task + dispatchMain() 實現 async 主程式

let mainTask = Task {
    await CoreService.run()
}

dispatchMain() // 保持 process 常駐
