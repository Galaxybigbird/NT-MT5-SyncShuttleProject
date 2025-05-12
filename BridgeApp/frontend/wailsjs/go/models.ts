export namespace main {
	
	export class Trade {
	    id: string;
	    base_id: string;
	    // Go type: time
	    time: any;
	    action: string;
	    quantity: number;
	    price: number;
	    total_quantity: number;
	    contract_num: number;
	    order_type?: string;
	    measurement_pips?: number;
	    raw_measurement?: number;
	
	    static createFrom(source: any = {}) {
	        return new Trade(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.base_id = source["base_id"];
	        this.time = this.convertValues(source["time"], null);
	        this.action = source["action"];
	        this.quantity = source["quantity"];
	        this.price = source["price"];
	        this.total_quantity = source["total_quantity"];
	        this.contract_num = source["contract_num"];
	        this.order_type = source["order_type"];
	        this.measurement_pips = source["measurement_pips"];
	        this.raw_measurement = source["raw_measurement"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

